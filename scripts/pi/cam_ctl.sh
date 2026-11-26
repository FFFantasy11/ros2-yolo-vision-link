#!/bin/bash
# 树莓派端状态与启停入口
#
# 用法：bash scripts/pi/cam_ctl.sh {start|stop|restart|status|log}
set -uo pipefail

case "${1:-status}" in
    start)   systemctl --user start vision-cam && sleep 2 && systemctl --user --no-pager status vision-cam | head -6 ;;
    stop)    systemctl --user stop vision-cam && echo "已停止" ;;
    restart) systemctl --user restart vision-cam && sleep 2 && systemctl --user --no-pager status vision-cam | head -6 ;;
    status)
        systemctl --user is-active --quiet vision-cam \
            && echo "服务: 运行中" || echo "服务: 未运行"
        echo -n "进程: "
        pgrep -af "vision_cam/lib/vision_cam/cam_no[d]e" || echo "无"
        echo -n "开机自启: "
        systemctl --user is-enabled vision-cam 2>/dev/null || echo "未启用"
        echo -n "linger: "
        loginctl show-user "$USER" -p Linger --value
        ;;
    log)     journalctl --user -u vision-cam -f ;;
    *)
        echo "用法: bash $0 {start|stop|restart|status|log}"
        exit 1
        ;;
esac
