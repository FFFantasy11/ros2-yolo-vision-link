#!/bin/bash
# 在主机桌面生成"双击运行"的启动 / 停止快捷方式
#
# 关键点（Ubuntu 24.04 / GNOME）：
#   1. .desktop 必须 chmod +x，否则双击只是打开文本
#   2. 必须标 metadata::trusted=true，否则 GNOME 会把它当"不受信任的启动器"，
#      双击时弹窗拒绝执行
#   3. Exec 里不能用 ~，桌面启动器不经过 shell 展开
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
DESK="$HOME/Desktop"

mkdir -p "$DESK"

write_entry() {
    local file="$1" name="$2" comment="$3" exec_path="$4" icon="$5"
    cat > "$DESK/$file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
Comment=$comment
Exec=$exec_path
Icon=$icon
Terminal=false
Categories=Utility;
EOF
    chmod +x "$DESK/$file"
    # 标记为可信启动器；某些文件管理器需要这个才能双击运行
    gio set "$DESK/$file" metadata::trusted true 2>/dev/null || true
    echo "已生成: $DESK/$file"
}

write_entry "YOLO视觉链路.desktop" \
    "YOLO 视觉链路" \
    "启动树莓派摄像头 + YOLO 实时检测网页" \
    "$PROJ/scripts/host/start_detect.sh" \
    "camera-photo"

write_entry "停止YOLO视觉链路.desktop" \
    "停止 YOLO 视觉链路" \
    "关闭主机端检测服务" \
    "$PROJ/scripts/host/stop_detect.sh" \
    "process-stop"

chmod +x "$PROJ/scripts/host/start_detect.sh" "$PROJ/scripts/host/stop_detect.sh" 2>/dev/null || true
echo
echo "提示：若桌面图标双击无反应，检查是否装了桌面图标扩展："
echo "  gnome-extensions list | grep -i ding || sudo apt install gnome-shell-extension-desktop-icons-ng"
