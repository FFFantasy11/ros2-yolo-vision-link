#!/usr/bin/env python3
"""阶段 6：FastAPI + WebSocket 实时检测服务。

架构：
    Pi  --ROS2/DDS(有线千兆)-->  [本进程]  --WebSocket-->  浏览器

    本进程内三条线：
      1. rclpy 节点：订阅 /image_raw/compressed（BEST_EFFORT + depth 1）
      2. worker 线程：spin_once 取最新帧 → YOLO 推理 → 更新共享槽
      3. uvicorn(主线程 asyncio)：每个 WebSocket 客户端轮询版本号，有新帧就发

为什么推理只做一次：
    推理 17ms 一帧，如果每个浏览器连接都独立推理一遍，3 个人看就是 3 倍 CPU。
    所以用「单一 worker 更新共享槽 + 所有客户端读同一份」的广播模型。

消息格式（二进制，一帧一条）：
    [4 字节 uint32 小端 = header 长度 N][N 字节 UTF-8 JSON][JPEG 字节]
    header 里带 w/h 和检测框坐标（原图像素坐标），前端按同一帧画框，
    因此框和画面在物理上不可能错位 —— 这是选这个协议的唯一理由。

用法：
    export FASTRTPS_DEFAULT_PROFILES_FILE=$HOME/wire.xml
    ~/venv/bin/python3 web_server.py --port 8000
    # 浏览器打开 http://<主机IP>:8000

    # 只检测人、提高置信度阈值
    ~/venv/bin/python3 web_server.py --classes 0 --conf 0.45
"""

import argparse
import json
import os
import struct
import threading
import time
from collections import deque

os.environ.setdefault("YOLO_VERBOSE", "False")

import cv2
import numpy as np
import rclpy
import torch
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage

HERE = os.path.dirname(os.path.abspath(__file__))


class FrameSource(Node):
    """订阅压缩图像，只保留最新一帧，推理放在 worker 里做。"""

    def __init__(self, args):
        super().__init__("web_detector")
        self.args = args

        qos = QoSProfile(
            depth=1,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        self.sub = self.create_subscription(
            CompressedImage, args.topic, self.on_img, qos
        )

        torch.set_num_threads(args.threads)
        from ultralytics import YOLO

        self.model = YOLO(args.model)
        self.classes = args.classes or None
        self.quality = args.quality

        self.frame = None
        self.stamp = 0.0
        self.n_recv = 0

        self.infer_ms = deque(maxlen=30)
        self.n_proc = 0
        self.t_last = time.monotonic()
        self.fps = 0.0

    def on_img(self, msg):
        # 回调里只解码并覆盖 —— 绝不在这里跑推理，否则 executor 被占住就积压
        buf = np.frombuffer(bytes(msg.data), dtype=np.uint8)
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if img is None:
            return
        self.frame = img
        self.stamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        self.n_recv += 1

    def process(self):
        """取最新帧推理一次。返回 (jpeg_bytes, header_dict) 或 None。"""
        img = self.frame
        if img is None:
            return None
        stamp = self.stamp
        self.frame = None          # 取走即清空，处理期间来的新帧直接覆盖

        t0 = time.perf_counter()
        res = self.model.predict(
            img,
            imgsz=self.args.imgsz,
            conf=self.args.conf,
            classes=self.classes,
            verbose=False,
        )
        inf = (time.perf_counter() - t0) * 1000
        self.infer_ms.append(inf)

        r = res[0]
        dets = []
        for b in r.boxes:
            x1, y1, x2, y2 = (float(v) for v in b.xyxy[0].tolist())
            cid = int(b.cls[0])
            dets.append(
                {
                    "x1": round(x1, 1),
                    "y1": round(y1, 1),
                    "x2": round(x2, 1),
                    "y2": round(y2, 1),
                    "cls": cid,
                    "name": r.names[cid],
                    "conf": round(float(b.conf[0]), 3),
                }
            )

        # 发原图，框交给前端画：矢量清晰、可交互、不必服务端改像素
        ok, buf = cv2.imencode(
            ".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), self.quality]
        )
        if not ok:
            return None

        self.n_proc += 1
        now = time.monotonic()
        dt = now - self.t_last
        if dt >= 1.0:
            self.fps = self.n_proc / dt
            self.n_proc = 0
            self.t_last = now

        header = {
            "w": int(img.shape[1]),
            "h": int(img.shape[0]),
            "dets": dets,
            "fps": round(self.fps, 1),
            "infer_ms": round(inf, 1),
            "lat_ms": round((time.time() - stamp) * 1000, 1),
            "n": self.n_recv,
        }
        return buf.tobytes(), header


class Hub:
    """推理结果的共享槽。worker 写，WebSocket 客户端读。"""

    def __init__(self):
        self.jpeg = None
        self.header = b""
        self.ver = 0

    def put(self, jpeg, header):
        self.header = json.dumps(header, ensure_ascii=False).encode("utf-8")
        self.jpeg = jpeg
        self.ver += 1

    def pack(self):
        return struct.pack("<I", len(self.header)) + self.header + self.jpeg


def build_app(src, hub):
    app = FastAPI(title="YOLO 实时检测")

    @app.get("/")
    def index():
        return FileResponse(os.path.join(HERE, "web", "index.html"))

    @app.get("/health")
    def health():
        return {"ok": True, "frames": src.n_recv, "ver": hub.ver}

    @app.websocket("/ws")
    async def ws_endpoint(ws: WebSocket):
        import asyncio

        await ws.accept()
        last = -1
        try:
            while True:
                if hub.ver != last and hub.jpeg is not None:
                    last = hub.ver
                    await ws.send_bytes(hub.pack())
                await asyncio.sleep(0.008)
        except (WebSocketDisconnect, RuntimeError):
            pass

    return app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--topic", default="/image_raw/compressed")
    ap.add_argument("--model", default=os.path.expanduser("~/yolov8n.pt"))
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.4)
    ap.add_argument("--classes", type=int, nargs="*", default=None)
    ap.add_argument("--quality", type=int, default=80)
    ap.add_argument("--threads", type=int, default=8)
    args = ap.parse_args()

    rclpy.init()
    src = FrameSource(args)
    hub = Hub()

    def worker():
        while rclpy.ok():
            try:
                rclpy.spin_once(src, timeout_sec=0.02)
            except Exception:
                break
            out = src.process()
            if out:
                hub.put(*out)

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    print(f"服务启动：http://{args.host}:{args.port}  (Ctrl-C 停止)", flush=True)

    app = build_app(src, hub)
    try:
        uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
    finally:
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
