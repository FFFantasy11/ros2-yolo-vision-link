#!/bin/bash
# 手动启动采集节点（前台运行，Ctrl-C 停止）——调试用
#
# 日常开机自启走 systemd：systemctl --user start vision-cam
# 两者不能同时跑：摄像头是独占设备，第二个进程会报 Device or resource busy。
#
# 用法：
#   bash scripts/pi/start_cam.sh
#   bash scripts/pi/start_cam.sh --ros-args -p exposure:=200     # 暗环境调亮
#   bash scripts/pi/start_cam.sh --ros-args -p classes:=...      # 不支持，仅示意
set -o pipefail   # 不能用 set -u：ROS 的 setup.bash 会引用未定义变量

PROJ="${VISION_PROJECT:-$HOME/vision_project}"
source /opt/ros/jazzy/setup.bash
source "$PROJ/ros2_ws/install/setup.bash"
# DDS 绑定到有线口；没有这个文件（比如纯 WiFi 运行）就不设，走默认传输
[ -f "$PROJ/config/wire.xml" ] && export FASTRTPS_DEFAULT_PROFILES_FILE="$PROJ/config/wire.xml"

if systemctl --user is-active --quiet vision-cam 2>/dev/null; then
    echo "⚠️ 开机自启服务 vision-cam 正在运行，会抢摄像头。先执行："
    echo "   systemctl --user stop vision-cam"
    exit 1
fi

exec "$PROJ/ros2_ws/install/vision_cam/lib/vision_cam/cam_node" \
    --ros-args \
    --params-file "$PROJ/ros2_ws/install/vision_cam/share/vision_cam/config/cam.yaml" \
    "$@"
