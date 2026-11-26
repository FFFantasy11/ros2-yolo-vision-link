#!/usr/bin/env python3
"""阶段 1 探针：订阅压缩图像话题，测「帧率 / 带宽 / 抖动 / 延迟」。

它不推理、不显示（除非加 --show），只回答一个问题：这条链路到底能跑多快。

用法：
    python3 probe.py                     # 一直跑，Ctrl-C 结束看汇总
    python3 probe.py --seconds 30        # 跑 30 秒自动汇总
    python3 probe.py --show              # 附带画面（opencv-python 需要已安装）
    python3 probe.py --topic /image_raw/compressed

注意：延迟那一列的绝对值里含两台机器的时钟偏差。
    如果两机都连过互联网对时，误差通常 <10ms，可以直接信；
    如果 Pi 只连了网线（网关留空），它没有时间源，那这一列只能看「相对变化」。
"""

import argparse
import collections
import time

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import CompressedImage


def pct(buf, p):
    return float(np.percentile(buf, p)) if len(buf) else float("nan")


class Probe(Node):
    def __init__(self, topic, preview):
        super().__init__("image_probe")
        qos = QoSProfile(
            depth=1,
            history=HistoryPolicy.KEEP_LAST,
            reliability=ReliabilityPolicy.BEST_EFFORT,
        )
        self.sub = self.create_subscription(CompressedImage, topic, self.on_msg, qos)

        self.total_n = 0
        self.total_bytes = 0
        self.stalls = 0
        self.gaps = collections.deque(maxlen=2000)
        self.lat = collections.deque(maxlen=2000)

        self.win_n = 0
        self.win_bytes = 0
        self.win_t = time.monotonic()

        self.last_t = None
        self.preview = preview
        self.frame = None

    def on_msg(self, msg):
        now = time.monotonic()
        size = len(msg.data)

        if self.last_t is not None:
            gap = now - self.last_t
            self.gaps.append(gap)
            if gap > 0.2:
                self.stalls += 1
        self.last_t = now

        self.total_n += 1
        self.total_bytes += size
        self.win_n += 1
        self.win_bytes += size

        st = msg.header.stamp
        if st.sec or st.nanosec:
            self.lat.append(time.time() - (st.sec + st.nanosec * 1e-9))

        if self.preview:
            self.frame = np.frombuffer(msg.data, dtype=np.uint8).copy()

    def maybe_report(self, elapsed):
        now = time.monotonic()
        dt = now - self.win_t
        if dt < 1.0:
            return
        fps = self.win_n / dt
        mbps = self.win_bytes * 8 / dt / 1e6
        kb = (self.win_bytes / self.win_n / 1024) if self.win_n else 0.0
        jit = pct(self.gaps, 95) * 1000
        lat = pct(self.lat, 50) * 1000
        print(
            f"[{elapsed:6.1f}s] {fps:5.1f} fps | {mbps:6.1f} Mbps | {kb:6.1f} KB/帧 "
            f"| 间隔p95 {jit:5.1f} ms | 延迟p50 {lat:6.1f} ms | 卡顿 {self.stalls}",
            flush=True,
        )
        self.win_n = 0
        self.win_bytes = 0
        self.win_t = now

    def summary(self, elapsed):
        print("\n" + "═" * 62)
        if self.total_n == 0:
            print("一帧都没收到。先确认：Pi 上 /image_raw/compressed 有发布者吗？")
            print("  ros2 topic info /image_raw/compressed -v")
            print("  两端 ROS_DOMAIN_ID 是否一致？网线是否通？")
            return
        dur = max(elapsed, 1e-6)
        print(f"总帧数      {self.total_n}   用时 {dur:.1f}s")
        print(f"平均帧率    {self.total_n / dur:.1f} fps")
        print(f"平均带宽    {self.total_bytes * 8 / dur / 1e6:.1f} Mbps")
        print(f"平均帧大小  {self.total_bytes / self.total_n / 1024:.1f} KB")
        print(
            f"帧间隔      p50 {pct(self.gaps, 50) * 1000:.1f} / "
            f"p95 {pct(self.gaps, 95) * 1000:.1f} / "
            f"p99 {pct(self.gaps, 99) * 1000:.1f} ms"
        )
        print(
            f"端到端延迟  p50 {pct(self.lat, 50) * 1000:.1f} / "
            f"p95 {pct(self.lat, 95) * 1000:.1f} ms  (含两机时钟偏差)"
        )
        print(f"卡顿次数    {self.stalls}  (>200ms 的间隔)")

        worst = pct(self.gaps, 99)
        if worst > 0.2:
            print("\n判读：p99 间隔超过 200ms，链路在抖。优先怀疑 WiFi、USB 供电或 Pi 在降频。")
        elif self.total_n / dur < 24 and self.total_n / dur > 5:
            print("\n判读：帧率明显低于 30。若 Pi 端 top 里 v4l2_camera 占用不高，问题在采集侧（供电/线材/口）。")
        else:
            print("\n判读：帧率与抖动都正常，可以进入阶段 2。")
        print("═" * 62)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", default="/image_raw/compressed")
    ap.add_argument("--seconds", type=float, default=0.0, help="0 表示一直跑")
    ap.add_argument("--show", action="store_true", help="附带画面预览，按 ESC 退出")
    args = ap.parse_args()

    rclpy.init()
    node = Probe(args.topic, args.show)
    print(f"订阅 {args.topic} … Ctrl-C 结束\n")
    t0 = time.monotonic()

    cv2 = None
    if args.show:
        import cv2 as _cv2

        cv2 = _cv2

    try:
        while rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.02)

            if cv2 is not None and node.frame is not None:
                img = cv2.imdecode(node.frame, cv2.IMREAD_COLOR)
                node.frame = None
                if img is not None:
                    cv2.imshow("stream", img)
                    if cv2.waitKey(1) & 0xFF == 27:
                        break

            node.maybe_report(time.monotonic() - t0)
            if args.seconds and time.monotonic() - t0 >= args.seconds:
                break
    except KeyboardInterrupt:
        pass
    finally:
        node.summary(time.monotonic() - t0)
        node.destroy_node()
        rclpy.shutdown()
        if cv2 is not None:
            cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
