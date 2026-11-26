#!/usr/bin/env python3
"""阶段 4：树莓派单节点出流（V4L2 取流 → JPEG → CompressedImage）。

为什么不用 usb_cam + image_transport republish：
    usb_cam 发布 /image_raw 用的是 RELIABLE + KEEP_LAST(100)。
    640x480 YUYV 一帧 614400 字节，depth 100 就是 61MB 历史；
    下游一旦跟不上，积压只增不减，实测端到端延迟从 950ms 一路涨到 1177ms。
    Jazzy 的 usb_cam 没有暴露 publisher QoS 参数，改不了，所以换这个节点：
      1) 直接发 CompressedImage，QoS = BEST_EFFORT + depth 1，物理上不可能积压
      2) 少一次 12MB/s 的本机 raw 转发，Pi 的 CPU 和内存都省下来
      3) 进程从 4 个降到 1 个

用法：
    export FASTRTPS_DEFAULT_PROFILES_FILE=$HOME/wire.xml
    python3 cam_pub.py                      # 默认 /dev/video0，MJPG 640x480@20，q80
    python3 cam_pub.py --fourcc YUYV        # 某些模组 MJPG 不可用时退回 YUYV
    python3 cam_pub.py --quality 70 --fps 15
    python3 cam_pub.py --print-every 20     # 每 20 帧打印一次实测帧率

先设好摄像头控件（曝光必须手动锁死，否则暗光下会自动降帧）：
    v4l2-ctl -d /dev/video0 --set-ctrl=exposure_dynamic_framerate=0 \
             --set-ctrl=auto_exposure=1 --set-ctrl=exposure_time_absolute=30 \
             --set-ctrl=gain=63 --set-ctrl=brightness=0
"""

import argparse
import subprocess
import time

import cv2
import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage


class CamPublisher(Node):
    def __init__(self, args):
        super().__init__("cam_pub")
        self.args = args

        # BEST_EFFORT + depth 1 是关键：宁可丢帧，绝不排队。
        # 排队带来的延迟对"看画面"毫无价值，丢掉的旧帧反而更接近真实。
        qos = QoSProfile(
            depth=1,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        self.pub = self.create_publisher(CompressedImage, args.topic, qos)

        self.cap = cv2.VideoCapture(args.device, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            raise SystemExit(f"打不开 {args.device}")

        # FOURCC 必须在宽高之前设，否则驱动可能锁到别的格式上
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*args.fourcc))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
        self.cap.set(cv2.CAP_PROP_FPS, args.fps)
        # 缓冲数不能设 1！实测 buffersize=1 时帧率刚好减半（20fps 的模组只剩 10fps）：
        # 单缓冲下必须等缓冲区回收才能重新入队，驱动每两帧才能交出一帧。
        # 实测 1→10.1fps、4→19.9fps、8→19.9fps，取 4 兼顾延迟。
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, args.buffers)

        w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        # 关键：打开设备会把控件恢复成默认值（自动曝光 + 允许动态降帧）。
        # 暗光下自动曝光会把曝光拉到 100ms，帧率直接掉到 10fps —— 阶段 1 踩过同一个坑。
        # 所以必须在 open 之后重新锁死，顺序也不能变。
        if not args.no_ctrls:
            for ctrl in (
                "exposure_dynamic_framerate=0",
                "auto_exposure=1",
                f"exposure_time_absolute={args.exposure}",
                f"gain={args.gain}",
                "brightness=0",
            ):
                subprocess.run(
                    ["v4l2-ctl", "-d", args.device, f"--set-ctrl={ctrl}"],
                    check=False,
                    capture_output=True,
                )

        self.get_logger().info(
            f"{args.device} {args.fourcc} {w}x{h} @{args.fps} → {args.topic} (q{args.quality})"
        )

        self.n = 0
        self.t0 = time.monotonic()
        self.timer = self.create_timer(1.0 / args.fps, self.tick)

    def tick(self):
        ok, frame = self.cap.read()
        if not ok or frame is None:
            self.get_logger().warn("取帧失败", throttle_duration_sec=5.0)
            return

        ok, buf = cv2.imencode(
            ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), self.args.quality]
        )
        if not ok:
            return

        msg = CompressedImage()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = self.args.frame_id
        msg.format = "jpeg"
        msg.data = buf.tobytes()
        self.pub.publish(msg)

        self.n += 1
        if self.args.print_every and self.n % self.args.print_every == 0:
            dt = time.monotonic() - self.t0
            self.get_logger().info(
                f"{self.n} 帧 | {self.n / dt:5.1f} fps | {len(msg.data) / 1024:5.1f} KB/帧"
            )

    def close(self):
        self.cap.release()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--topic", default="/image_raw/compressed")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--fps", type=float, default=20.0)
    ap.add_argument("--fourcc", default="MJPG")
    ap.add_argument("--quality", type=int, default=80)
    ap.add_argument("--frame-id", default="camera_optical_frame")
    ap.add_argument("--print-every", type=int, default=40)
    ap.add_argument("--exposure", type=int, default=30)  # 单位 100µs，30 = 3ms
    ap.add_argument("--gain", type=int, default=63)
    ap.add_argument("--no-ctrls", action="store_true")  # 不想让节点动控件时加这个
    ap.add_argument("--buffers", type=int, default=4)  # 必须 >1，见 __init__ 注释
    args = ap.parse_args()

    rclpy.init()
    node = CamPublisher(args)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.close()
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
