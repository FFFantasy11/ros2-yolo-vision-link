#!/usr/bin/env python3
"""主机端检测节点：订阅压缩图 -> YOLOv8 推理 -> HTTP/WebSocket 推流。

为什么这个节点是 Python（其余节点是 C++）：
    YOLOv8 的推理链是 ultralytics + PyTorch。试过用 C++ 等价替换——
    OpenCV 4.6 的 dnn 模块解析不了 YOLOv8 检测头（Add 广播断言失败，
    简化图后又在 forward 阶段炸），ONNX Runtime 的 C++ 开发包在离线环境
    里也拿不到头文件。强行替换会把一个稳定跑通的链路变成维护负担，
    所以推理节点保留 Python，把能拿到的收益（Pi 端采集）放到 C++ 里。

架构：
    Pi --ROS2/DDS(有线千兆)--> [本进程] --WebSocket--> 浏览器

    本进程内三条线：
      1. rclpy 节点：订阅 /image_raw/compressed（BEST_EFFORT + depth 1）
      2. worker 线程：spin_once 取最新帧 -> 推理 -> 更新共享槽
      3. uvicorn(主线程 asyncio)：每个 WebSocket 客户端轮询版本号，有新帧就发

为什么推理只做一次：
    推理 17ms 一帧，如果每个浏览器连接都独立推理一遍，3 个人看就是 3 倍 CPU。
    所以用「单一 worker 更新共享槽 + 所有客户端读同一份」的广播模型。

消息格式（二进制，一帧一条）：
    [4 字节 uint32 小端 = header 长度 N][N 字节 UTF-8 JSON][JPEG 字节]
    header 里带 w/h 和检测框坐标（原图像素坐标），前端按同一帧画框，
    因此框和画面在物理上不可能错位 —— 这是选这个协议的唯一理由。

用法：
    ros2 run vision_detect detect_node            # 需要 venv 提供 torch/ultralytics
    scripts/host/start_detect.sh                  # 封装好的启动脚本（推荐）
    浏览器打开 http://<主机IP>:8000
"""

import asyncio
import json
import os
import struct
import threading
import time

import cv2
import numpy as np
import rclpy
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage


class FrameSource(Node):
    """订阅压缩图像，只保留最新一帧；推理放在 worker 线程里做。"""

    def __init__(self):
        super().__init__('vision_detect')
        self._declare_params()

        # BEST_EFFORT + depth 1：和发布端一致，慢了就丢帧，绝不排队
        qos = QoSProfile(
            depth=1,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        self.sub = self.create_subscription(
            CompressedImage, self.topic, self._on_img, qos
        )

        # torch 的线程数必须在加载模型之前设，否则不生效
        import torch

        torch.set_num_threads(self.threads)
        from ultralytics import YOLO

        self.model = YOLO(self.model_path)
        self.get_logger().info(
            f'订阅 {self.topic} | 模型 {self.model_path} | imgsz {self.imgsz} | '
            f'conf {self.conf} | classes {self.classes or "全部"}'
        )

        self.frame = None
        self.stamp = 0.0
        self.n_recv = 0
        self.n_proc = 0
        self.fps = 0.0
        self._t_last = time.monotonic()

    def _declare_params(self):
        """所有可调项都是 ROS 参数，改 config/detect.yaml 即可，不用改代码。"""
        gp = self.declare_parameter
        self.topic = gp('topic', '/image_raw/compressed').value
        self.model_path = os.path.expanduser(gp('model', '~/yolov8n.pt').value)
        self.imgsz = gp('imgsz', 640).value
        self.conf = gp('conf', 0.4).value
        self.iou = gp('iou', 0.7).value
        self.quality = gp('quality', 80).value
        self.threads = gp('threads', 8).value
        self.port = gp('port', 8000).value
        self.bind = gp('bind', '0.0.0.0').value
        # 声明为整数数组而不给默认值：空数组表示不限类别
        classes = gp('classes', Parameter.Type.INTEGER_ARRAY).value
        self.classes = [int(c) for c in classes] if classes else None

        if not os.path.isfile(self.model_path):
            raise SystemExit(f'找不到模型 {self.model_path}')

    def _on_img(self, msg):
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
            imgsz=self.imgsz,
            conf=self.conf,
            iou=self.iou,
            classes=self.classes,
            verbose=False,
        )
        infer_ms = (time.perf_counter() - t0) * 1000.0

        r = res[0]
        dets = []
        for b in r.boxes:
            x1, y1, x2, y2 = (float(v) for v in b.xyxy[0].tolist())
            cid = int(b.cls[0])
            dets.append(
                {
                    'x1': round(x1, 1),
                    'y1': round(y1, 1),
                    'x2': round(x2, 1),
                    'y2': round(y2, 1),
                    'cls': cid,
                    'name': r.names[cid],
                    'conf': round(float(b.conf[0]), 3),
                }
            )

        # 发原图，框交给前端画：矢量清晰、可交互、不必服务端改像素
        ok, buf = cv2.imencode(
            '.jpg', img, [int(cv2.IMWRITE_JPEG_QUALITY), self.quality]
        )
        if not ok:
            return None

        self.n_proc += 1
        now = time.monotonic()
        dt = now - self._t_last
        if dt >= 1.0:
            self.fps = self.n_proc / dt
            self.n_proc = 0
            self._t_last = now

        header = {
            'w': int(img.shape[1]),
            'h': int(img.shape[0]),
            'dets': dets,
            'fps': round(self.fps, 1),
            'infer_ms': round(infer_ms, 1),
            'lat_ms': round((time.time() - stamp) * 1000.0, 1),
            'n': self.n_recv,
        }
        return buf.tobytes(), header


class Hub:
    """推理结果的共享槽。worker 写，WebSocket 客户端读。"""

    def __init__(self):
        self.jpeg = None
        self.header = b''
        self.ver = 0

    def put(self, jpeg, header):
        self.header = json.dumps(header, ensure_ascii=False).encode('utf-8')
        self.jpeg = jpeg
        self.ver += 1

    def pack(self):
        return struct.pack('<I', len(self.header)) + self.header + self.jpeg


def index_html_path():
    """优先用安装目录下的前端文件，开发态回退到源码目录。"""
    try:
        from ament_index_python.packages import get_package_share_directory

        return os.path.join(
            get_package_share_directory('vision_detect'), 'web', 'index.html'
        )
    except Exception:
        here = os.path.dirname(os.path.abspath(__file__))
        return os.path.join(here, 'web', 'index.html')


def build_app(src, hub, page):
    app = FastAPI(title='YOLO 实时检测')

    @app.get('/')
    def index():
        return FileResponse(page)

    @app.get('/health')
    def health():
        return {'ok': True, 'frames': src.n_recv, 'ver': hub.ver}

    @app.websocket('/ws')
    async def ws_endpoint(ws: WebSocket):
        await ws.accept()
        last = -1
        try:
            while True:
                if hub.ver != last and hub.jpeg is not None:
                    last = hub.ver
                    await ws.send_bytes(hub.pack())
                # 8ms 轮询：比 20fps 的帧间隔短一个数量级，
                # 新增延迟上限 8ms，换来推流线程几乎不占 CPU
                await asyncio.sleep(0.008)
        except (WebSocketDisconnect, RuntimeError):
            pass

    return app


def main(args=None):
    rclpy.init(args=args)
    src = FrameSource()
    hub = Hub()

    page = index_html_path()
    if not os.path.isfile(page):
        src.get_logger().error(f'找不到前端页面 {page}')
        rclpy.shutdown()
        return 1

    def worker():
        while rclpy.ok():
            try:
                rclpy.spin_once(src, timeout_sec=0.02)
            except Exception:
                break
            out = src.process()
            if out:
                hub.put(*out)

    threading.Thread(target=worker, daemon=True).start()
    src.get_logger().info(f'网页服务已启动：http://{src.bind}:{src.port}')

    try:
        uvicorn.run(build_app(src, hub, page), host=src.bind, port=src.port,
                    log_level='warning')
    except KeyboardInterrupt:
        pass
    finally:
        rclpy.try_shutdown()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
