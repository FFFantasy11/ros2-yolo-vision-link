#!/bin/bash
# 网页检测服务的启停管理
#
# 用法：
#   bash ~/web_ctl.sh start       启动（后台，日志 /tmp/web.log）
#   bash ~/web_ctl.sh stop        停止
#   bash ~/web_ctl.sh restart     重启（改了参数后用这个）
#   bash ~/web_ctl.sh status      看进程、端口、收帧数
#   bash ~/web_ctl.sh log         跟踪日志（Ctrl-C 退出）
#
# 为什么不直接 nohup + pkill：
#   1) pkill -f 会匹配到 ssh 自己的命令行，把会话杀掉（实测踩过，退出码 255）
#   2) 没有 pidfile 就无法判断"到底在不在跑"，容易起出两份抢摄像头
# 所以用 pidfile 精确管理。

PIDFILE=/tmp/yolo-web.pid
LOG=/tmp/web.log
PORT=8000

pid_alive() {
    [ -f "$PIDFILE" ] || return 1
    local p
    p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

do_start() {
    if pid_alive; then
        echo "已在运行 (pid $(cat $PIDFILE))，端口 $PORT"
        return 0
    fi
    rm -f "$PIDFILE"
    (setsid nohup bash "$HOME/start_web.sh" --port "$PORT" > "$LOG" 2>&1 < /dev/null &)
    sleep 9
    local p
    # 取真正跑 web_server.py 的 python 进程，不要取到外层 bash
    p=$(pgrep -f "python.*web_server\.py" | head -1)
    if [ -n "$p" ]; then
        echo "$p" > "$PIDFILE"
        echo "已启动 (pid $p)"
        echo "访问地址（Windows 用 WiFi 那个，不要用 192.168.10.x）："
        ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 \
            | while read -r a; do
                case "$a" in
                    192.168.10.*) echo "  http://$a:$PORT   (有线直连，只有 Pi 能访问)" ;;
                    *)            echo "  http://$a:$PORT" ;;
                esac
              done
    else
        echo "启动失败，日志最后几行："
        tail -12 "$LOG"
        return 1
    fi
}

do_stop() {
    if pid_alive; then
        kill "$(cat $PIDFILE)" 2>/dev/null
        sleep 2
        pid_alive && kill -9 "$(cat $PIDFILE)" 2>/dev/null
        rm -f "$PIDFILE"
        echo "已停止"
    else
        rm -f "$PIDFILE"
        # 兜底：可能上次异常退出没留 pidfile
        local p
        p=$(pgrep -f "python.*web_server\.py" | head -1)
        if [ -n "$p" ]; then
            kill "$p" 2>/dev/null; sleep 2
            echo "已停止（清理残留 pid $p）"
        else
            echo "本来就没在跑"
        fi
    fi
}

do_status() {
    if pid_alive; then
        echo "进程: 运行中 (pid $(cat $PIDFILE))"
    else
        echo "进程: 未运行"
    fi
    echo "端口: $(ss -tln 2>/dev/null | grep -c ":$PORT ") 个监听"
    echo -n "健康: "
    curl -s --max-time 4 "http://127.0.0.1:$PORT/health" || echo "(无响应)"
    echo
}

case "${1:-status}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 1; do_start ;;
    status)  do_status ;;
    log)     tail -f "$LOG" ;;
    *)
        echo "用法: bash $0 {start|stop|restart|status|log}"
        exit 1
        ;;
esac
