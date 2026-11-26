#!/bin/bash
# 启动主机端检测服务并打开浏览器（桌面快捷方式调用的就是它）
#
# 行为：
#   1. 已在跑 -> 直接开浏览器，不重复起进程（避免抢 8000 端口）
#   2. 没在跑 -> 后台起 detect_node，等 /health 通，再开浏览器
#   3. 起不来 -> 弹桌面通知并把日志末尾贴出来
#
# 用 setsid + nohup：脚本退出后节点继续跑，关掉终端也不影响。
# 注意不能用 set -u：ROS 的 setup.bash 会引用未定义变量 AMENT_TRACE_SETUP_FILES，
# 一开 -u 脚本就在这里静默退出（实测踩过，桌面双击表现为"毫无反应"）。
set -o pipefail

PROJ="${VISION_PROJECT:-$HOME/vision_project}"
WS="$PROJ/ros2_ws"
URL="http://127.0.0.1:8000"
LOG=/tmp/vision-detect.log
PIDFILE=/tmp/vision-detect.pid
PY="${VISION_PYTHON:-$HOME/venv/bin/python3}"

open_browser() {
    command -v xdg-open > /dev/null && xdg-open "$URL" > /dev/null 2>&1 &
}

pid_alive() {
    [ -f "$PIDFILE" ] || return 1
    local p
    p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

if pid_alive; then
    echo "已在运行 (pid $(cat "$PIDFILE"))，直接打开页面"
    open_browser
    exit 0
fi

if [ ! -x "$PY" ]; then
    msg="找不到 $PY（YOLO 推理依赖 venv 里的 ultralytics/torch）"
    echo "$msg"
    notify-send "视觉链路启动失败" "$msg" 2>/dev/null
    exit 1
fi

if ! curl -s --max-time 1 "$URL/health" > /dev/null 2>&1; then
    rm -f "$PIDFILE"
    source /opt/ros/jazzy/setup.bash
    source "$WS/install/setup.bash"
    # DDS 绑定到有线口；没有这个文件（比如纯 WiFi 运行）就不设，走默认传输
[ -f "$PROJ/config/wire.xml" ] && export FASTRTPS_DEFAULT_PROFILES_FILE="$PROJ/config/wire.xml"

    setsid nohup "$PY" \
        "$WS/install/vision_detect/lib/vision_detect/detect_node" \
        --ros-args \
        --params-file "$WS/install/vision_detect/share/vision_detect/config/detect.yaml" \
        > "$LOG" 2>&1 < /dev/null &

    # YOLO 权重加载 + DDS 发现约 5~10s，最多等 25s
    for _ in $(seq 1 50); do
        if curl -s --max-time 1 "$URL/health" > /dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
fi

if curl -s --max-time 2 "$URL/health" > /dev/null 2>&1; then
    pgrep -f "vision_detect/detect_nod[e]" | head -1 > "$PIDFILE"
    echo "已启动 (pid $(cat "$PIDFILE"))：$URL"
    open_browser
else
    tail -20 "$LOG" 2>/dev/null
    notify-send "视觉链路启动失败" "详见 $LOG" 2>/dev/null
    exit 1
fi
