#!/bin/bash
# 阶段 4：树莓派单节点出流启动脚本
#
# 用法：
#   bash ~/start_cam_pub.sh                 # 前台运行（Ctrl-C 停）
#   nohup bash ~/start_cam_pub.sh > /tmp/cam.log 2>&1 &    # 后台运行
#   bash ~/start_cam_pub.sh --exposure 200  # 暗环境调亮（单位 100µs，200 = 20ms）
#
# 前置条件（只需做一次）：
#   1) ~/cam_pub.py 已存在
#   2) ~/wire.xml 已存在（Fast DDS 有线口白名单）
#   3) 摄像头接在 /dev/video0

# 绝对不能用 set -u：ROS 的 setup.bash 会引用未定义变量 AMENT_TRACE_SETUP_FILES，
# 一开 -u 脚本立刻退出，且不打印任何有用信息。
set -o pipefail

source /opt/ros/jazzy/setup.bash

# 强制 DDS 走有线口：不设这个，视频流会 100% 跑到 WiFi 上（实测帧间隔 p99 从 52ms 恶化到 210ms）
if [ -f "$HOME/wire.xml" ]; then
    export FASTRTPS_DEFAULT_PROFILES_FILE="$HOME/wire.xml"
else
    echo "警告：$HOME/wire.xml 不存在，DDS 可能走 WiFi" >&2
fi

# 摄像头格式与参数：
#   YUYV —— 这个模组 MJPG 上限只有 10fps，YUYV 才能到 20fps
#   --buffers 4 —— 不能设 1，单缓冲会让帧率刚好减半
#   --exposure 100 —— 10ms 曝光，室内正常亮度且不掉帧；开灯后可降到 30
exec python3 "$HOME/cam_pub.py" \
    --device /dev/video0 \
    --fourcc YUYV \
    --width 640 --height 480 --fps 20 \
    --quality 80 \
    --buffers 4 \
    --exposure 100 \
    "$@"
