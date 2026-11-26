#!/bin/bash
# 安装树莓派开机自启（用户级 systemd 服务 + linger）
#
# 为什么用用户级 systemd 而不是系统级：
#   系统级要 sudo，且单元里得再写一遍 User=/Group= 和摄像头权限；
#   用户级配合 linger，同样能做到"开机即起、不需登录"，且不用动 /etc。
#
# 用法（在树莓派上）：bash ~/vision_project/scripts/pi/install_service.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"

echo "项目目录: $PROJ"

if [ ! -x "$PROJ/ros2_ws/install/vision_cam/lib/vision_cam/cam_node" ]; then
    echo "❌ 找不到已编译的 cam_node，请先执行："
    echo "   cd $PROJ/ros2_ws && source /opt/ros/jazzy/setup.bash && colcon build --packages-select vision_cam"
    exit 1
fi

if [ ! -f "$PROJ/config/wire.xml" ]; then
    echo "❌ 缺少 $PROJ/config/wire.xml（应为 wire-pi.xml 的副本）"
    echo "   在 Windows 上跑 bash scripts/deploy.sh pi 会自动放好"
    exit 1
fi

mkdir -p "$UNIT_DIR"
sed "s|@HOME@|$HOME|g" "$HERE/vision-cam.service.in" > "$UNIT_DIR/vision-cam.service"

# linger：开机就拉起用户级 systemd，不用等 abc 登录
loginctl enable-linger "$USER" 2>/dev/null || echo "⚠️ enable-linger 失败，重启后需登录一次才会启动"

# 手动跑着的同名进程会和服务抢摄像头，先停掉
if pgrep -f "vision_cam/lib/vision_cam/cam_node" > /dev/null; then
    echo "停止手动启动的 cam_node …"
    pkill -f "vision_cam/lib/vision_cam/cam_node" || true
    sleep 1
fi

systemctl --user daemon-reload
systemctl --user enable vision-cam.service
systemctl --user restart vision-cam.service
sleep 3

echo "--- 服务状态 ---"
systemctl --user --no-pager status vision-cam.service | head -12
echo
echo "查看日志： journalctl --user -u vision-cam -f"
echo "停止服务： systemctl --user stop vision-cam"
