#!/bin/bash
# 停止主机端检测服务
#
# 为什么用 pidfile 而不是 pkill -f "detect_node"：
#   pkill -f 会匹配到自己在跑的这条命令行（字符串里就有 detect_node），
#   把 SSH 会话一起杀掉 —— 实测踩过，退出码 255。方括号技巧可以规避。
set -uo pipefail

PIDFILE=/tmp/vision-detect.pid

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
        sleep 0.3
    done
    kill -0 "$(cat "$PIDFILE")" 2>/dev/null && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    echo "已停止"
    exit 0
fi

rm -f "$PIDFILE"
# 兜底：上次异常退出没留 pidfile
P=$(pgrep -f "vision_detect/detect_nod[e]" | head -1)
if [ -n "$P" ]; then
    kill "$P" 2>/dev/null
    sleep 1
    kill -9 "$P" 2>/dev/null
    echo "已停止（清理残留进程 $P）"
else
    echo "本来就没在跑"
fi
