#!/bin/bash
# 主机端状态：进程 / 端口 / 收帧数 / 与 Pi 的链路
# 不能用 set -u：ROS 的 setup.bash 会引用未定义变量
set -o pipefail

PROJ="${VISION_PROJECT:-$HOME/vision_project}"
URL="http://127.0.0.1:8000"
PIDFILE=/tmp/vision-detect.pid

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "服务: 运行中 (pid $(cat "$PIDFILE"))"
else
    echo "服务: 未运行"
fi

echo "端口: $(ss -tln 2>/dev/null | grep -c ':8000 ') 个监听"
echo -n "健康: "
# frames 持续增长 = 链路活着；停住 = Pi 端没发
curl -s --max-time 4 "$URL/health" || echo "(无响应)"
echo

echo -n "话题: "
source /opt/ros/jazzy/setup.bash 2>/dev/null
source "$PROJ/ros2_ws/install/setup.bash" 2>/dev/null
# DDS 绑定到有线口；没有这个文件（比如纯 WiFi 运行）就不设，走默认传输
[ -f "$PROJ/config/wire.xml" ] && export FASTRTPS_DEFAULT_PROFILES_FILE="$PROJ/config/wire.xml"
# timeout 一定会返回非 0，不能直接用 A || B 判断，否则明明收到了也会报"没收到"
HZ=$(timeout 6 ros2 topic hz /image_raw/compressed 2>/dev/null | grep -m1 "average rate" || true)
echo "${HZ:-6 秒内没收到帧（检查 Pi 端）}"
