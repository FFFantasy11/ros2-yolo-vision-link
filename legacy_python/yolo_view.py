#!/usr/bin/env python3
"""阶段 5：主机端 YOLO 检测，本地窗口出框（或存图）。

订阅 Pi 发来的 /image_raw/compressed（BEST_EFFORT + depth 1），解码 → YOLO → 画框。

设计要点 —— 为什么不用"在回调里推理"：
    推理要 15ms，回调里做会让 executor 被占住，DDS 那边新帧继续来，
    一旦处理速度慢于到达速度，队列就会积压，延迟只增不减（阶段 4 踩过的坑）。
    这里改成：回调只做一件事 —— 把最新一帧覆盖到 self.latest，立刻返回；
    主循环才取帧、推理、画框。这样天然"只处理最新帧"，慢就丢帧，绝不排队。

用法：
    # 远程看（存图，不需要图形界面）
    ~/venv/bin/python3 yolo_view.py --save /tmp/yolo --save-every 30

    # 在主机屏幕前看（本地窗口）
    DISPLAY=:0 ~/venv/bin/python3 yolo_view.py --display

    # 调参
    ~/venv/bin/python3 yolo_view.py --display --conf 0.4 --imgsz 480 --classes 0 2 5 7

前置：
    export FASTRTPS_DEFAULT_PROFILES_FILE=$HOME/wire.xml
    ~/yolov8n.pt 已下载（6.3 MB）
"""

import argparse
import os
import time
from collections import deque

os.environ.setdefault("YOLO_VERBOSE", "False")

import cv2
import numpy as np
import rclpy
import torch
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage


class YoloView(Node):
    def __init__(self, args):
        super().__init__("yolo_view")
        self.args = args

        # depth=1 + BEST_EFFORT：与发布端匹配，物理上不可能积压
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

        self.latest = None          # 最新一帧（BGR）
        self.latest_stamp = 0.0     # 该帧的 ROS 时间戳（秒）
        self.n_recv = 0
        self.n_proc = 0     # 每秒清零，只用于算 fps
        self.n_total = 0    # 累计处理帧数，用于存图编号（不能和 n_proc 混用）
        self.n_det = 0
        self.saved = 0

        self.infer_ms = deque(maxlen=30)
        self.lat_ms = deque(maxlen=30)
        self.t_last = time.monotonic()
        self.fps = 0.0
        self.w = 0
        self.h = 0

        if args.save:
            os.makedirs(args.save, exist_ok=True)

        self.get_logger().info(
            f"订阅 {args.topic} | 模型 {os.path.basename(args.model)} "
            f"| imgsz {args.imgsz} conf {args.conf} "
            f"| {'窗口' if args.display else ''}{'存图' if args.save else ''}"
        )

    # 回调里什么都不做，只存最新帧 —— 这是不积压的关键
    def on_img(self, msg):
        buf = np.frombuffer(bytes(msg.data), dtype=np.uint8)
        frame = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if frame is None:
            return
        self.latest = frame
        self.latest_stamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
        self.n_recv += 1

    def process_once(self):
        """取最新帧推理一次。返回是否处理了。"""
        frame = self.latest
        if frame is None:
            return False
        stamp = self.latest_stamp
        self.latest = None          # 取走即清空，处理期间来的新帧直接覆盖

        t0 = time.perf_counter()
        res = self.model.predict(
            frame,
            imgsz=self.args.imgsz,
            conf=self.args.conf,
            classes=self.classes,
            verbose=False,
        )
        self.infer_ms.append((time.perf_counter() - t0) * 1000)

        self.lat_ms.append((time.time() - stamp) * 1000)
        vis = res[0].plot()         # ultralytics 画框、上色、标类别+置信度
        self.h, self.w = vis.shape[:2]
        self.n_proc += 1
        self.n_total += 1
        self.n_det += len(res[0].boxes)

        # 左下角叠加运行时指标
        inf = self.infer_ms[-1]
        lat = self.lat_ms[-1]
        txt = f"{self.fps:4.1f} fps | infer {inf:4.1f} ms | lat {lat:5.1f} ms | obj {len(res[0].boxes)}"
        cv2.putText(vis, txt, (8, self.h - 10),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(vis, txt, (8, self.h - 10),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA)

        if self.args.save and self.n_total % self.args.save_every == 1:
            p = os.path.join(self.args.save, f"f{self.n_total:05d}.jpg")
            cv2.imwrite(p, vis, [int(cv2.IMWRITE_JPEG_QUALITY), 88])
            self.saved += 1

        if self.args.display:
            cv2.imshow("yolo", vis)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                raise KeyboardInterrupt
        return True

    def tick_stats(self):
        now = time.monotonic()
        dt = now - self.t_last
        if dt >= 1.0:
            self.fps = self.n_proc / dt
            self.n_proc = 0
            self.t_last = now
            if self.infer_ms:
                s = sorted(self.infer_ms)
                l = sorted(self.lat_ms)
                self.get_logger().info(
                    f"{self.fps:4.1f} fps | 推理中位 {s[len(s)//2]:4.1f} ms "
                    f"| 延迟 p50 {l[len(l)//2]:5.1f} ms | 累计收到 {self.n_recv} 帧"
                )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", default="/image_raw/compressed")
    ap.add_argument("--model", default=os.path.expanduser("~/yolov8n.pt"))
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--classes", type=int, nargs="*", default=None,
                    help="只检测这些类别 id，例如 --classes 0 只检测人")
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--display", action="store_true", help="开本地窗口（需要 DISPLAY）")
    ap.add_argument("--save", default="", help="存带框图到目录")
    ap.add_argument("--save-every", type=int, default=30)
    ap.add_argument("--seconds", type=float, default=0, help="跑多少秒后退出，0=一直跑")
    args = ap.parse_args()

    rclpy.init()
    node = YoloView(args)
    t_start = time.monotonic()
    last_stat = 0.0

    try:
        # 手动循环而不是 rclpy.spin：这样才能"收 + 推理"交替进行
        while rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.05)
            if node.process_once():
                pass
            if time.monotonic() - last_stat >= 1.0:
                node.tick_stats()
                last_stat = time.monotonic()
            if args.seconds and time.monotonic() - t_start > args.seconds:
                break
    except KeyboardInterrupt:
        pass
    finally:
        if args.display:
            cv2.destroyAllWindows()
        inf = sorted(node.infer_ms)
        lat = sorted(node.lat_ms)
        if inf:
            print(
                f"\n汇总：处理 {node.n_recv} 帧 | 推理中位 {inf[len(inf)//2]:.1f} ms "
                f"| 延迟 p50 {lat[len(lat)//2]:.1f} ms | 共检出 {node.n_det} 个目标"
                f"{' | 存图 ' + str(node.saved) + ' 张' if node.saved else ''}"
            )
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
