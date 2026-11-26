#!/usr/bin/env bash
# 阶段 0.5：摄像头接入自检（在树莓派上跑）
# 目的不是"看一眼有没有图"，而是提前排除四类会让帧率莫名掉一半的问题：
#   1. 设备节点找错   2. 用户不在 video 组   3. USB 降速到 12Mbps   4. 供电不足欠压
#
# 用法： bash check_camera.sh [video设备，默认 /dev/video0]

DEV="${1:-/dev/video0}"

line() { printf '\n\033[1m%s\033[0m\n' "$1"; }

line "① 设备列表"
v4l2-ctl --list-devices 2>/dev/null || echo "  v4l2-ctl 不可用：sudo apt install v4l-utils"

line "② 目标设备 $DEV"
if [ -e "$DEV" ]; then
  echo "  存在"
  ls -l "$DEV"
else
  echo "  ✗ 不存在，检查上面的设备列表，或换 USB 口后重试"
fi

line "③ 权限"
if id -nG | grep -qw video; then
  echo "  ✓ 当前用户属于 video 组"
else
  echo "  ✗ 不在 video 组，会报 Permission denied"
  echo "    修复： sudo usermod -aG video \$USER  然后注销重新登录"
fi

line "④ 格式支持（重点看 MJPG 一行）"
v4l2-ctl -d "$DEV" --list-formats-ext 2>/dev/null | head -30

line "⑤ USB 链路速度"
# 480M = High Speed(USB2)，5G/10G = SuperSpeed(USB3)。摄像头本身一般是 USB2，
# 所以看到 480M 是正常的；但看到 12M 就是线材或口有问题。
lsusb -t 2>/dev/null | grep -iE 'uvc|cam|video|5000M|480M|12M' || echo "  lsusb -t 无输出"

line "⑥ 供电与降频状态（Pi 5 专有）"
if command -v vcgencmd >/dev/null 2>&1; then
  echo -n "  throttled 标志位: "; vcgencmd get_throttled
  echo "    0x0 = 健康。出现 0x50000/0x50005 表示曾经欠压或降频"
  echo "    → 必须用官方 27W(5V/5A) 电源，普通 5V/3A 会把 USB 口限流到 600mA"
  echo -n "  核心温度: "; vcgencmd measure_temp
else
  echo "  vcgencmd 不可用（非树莓派系统？）"
fi

line "⑦ 最近的 USB 异常（有 over-current 就是供电不够）"
dmesg 2>/dev/null | grep -iE 'over-current|under-voltage|device descriptor read|reset .*device|uvcvideo' | tail -12 || \
  echo "  需要 sudo 才有输出： sudo dmesg | grep -iE 'over-current|under-voltage'"

line "⑧ 采集节点依赖"
for p in v4l-utils libopencv-dev; do
  if dpkg -s "$p" >/dev/null 2>&1; then echo "  ✓ $p"; else echo "  ✗ $p 未安装（sudo apt install $p）"; fi
done
echo
echo "  vision_cam 直接走 V4L2，不依赖 usb_cam / v4l2_camera 等 ROS 摄像头包。"
