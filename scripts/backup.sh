#!/bin/bash
# 生成一份可直接恢复的备份快照（在 Windows Git Bash 里运行）
#
#   bash scripts/backup.sh                # 目录名用当天日期
#   bash scripts/backup.sh 2026-11-26     # 指定标签
#
# 产出：<工作空间>/backup/vision-<标签>/
#   01-主机端/     源码、脚本、已编译程序、桌面快捷方式
#   02-树莓派端/   源码、脚本、systemd 单元、已编译程序
#   03-配置脚本/   DDS/chrony 配置、部署与安装脚本、测试工具
#   04-依赖资源/   模型权重、依赖包版本清单
#   05-文档/       README、设计说明、验收记录、环境配置清单
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
ROOT="$(dirname "$PROJ")"
STAMP="${1:-$(date +%Y-%m-%d)}"
DEST="$ROOT/backup/vision-$STAMP"

# 两台机器的 ssh 目标，可用环境变量覆盖
PI_HOST="${PI_HOST:-pi}"
HOST_HOST="${HOST_HOST:-host}"

echo "备份到: $DEST"
[ -d "$DEST" ] && rm -rf "$DEST"
mkdir -p "$DEST/01-主机端/ros2_ws/src" "$DEST/01-主机端/scripts" \
         "$DEST/01-主机端/可执行文件" "$DEST/01-主机端/桌面快捷方式" \
         "$DEST/02-树莓派端/ros2_ws/src" "$DEST/02-树莓派端/scripts" \
         "$DEST/02-树莓派端/可执行文件" "$DEST/02-树莓派端/systemd" \
         "$DEST/03-配置脚本" "$DEST/04-依赖资源" "$DEST/05-文档"

# ── 01 主机端 ──────────────────────────────────────────────
cp -r "$PROJ/ros2_ws/src/vision_detect" "$PROJ/ros2_ws/src/vision_probe" \
      "$DEST/01-主机端/ros2_ws/src/"
cp -r "$PROJ/scripts/host" "$DEST/01-主机端/scripts/"
scp -q "$HOST_HOST":'~/vision_project/ros2_ws/install/vision_detect/lib/vision_detect/detect_node' \
    "$DEST/01-主机端/可执行文件/" 2>/dev/null || echo "  (跳过 detect_node，主机未连接)"
scp -q "$HOST_HOST":'~/vision_project/ros2_ws/install/vision_probe/lib/vision_probe/probe_node' \
    "$DEST/01-主机端/可执行文件/" 2>/dev/null || true
scp -q "$HOST_HOST":'~/Desktop/*.desktop' "$DEST/01-主机端/桌面快捷方式/" 2>/dev/null || true

# ── 02 树莓派端 ────────────────────────────────────────────
cp -r "$PROJ/ros2_ws/src/vision_cam" "$DEST/02-树莓派端/ros2_ws/src/"
cp -r "$PROJ/scripts/pi" "$DEST/02-树莓派端/scripts/"
scp -q "$PI_HOST":'~/vision_project/ros2_ws/install/vision_cam/lib/vision_cam/cam_node' \
    "$DEST/02-树莓派端/可执行文件/" 2>/dev/null || echo "  (跳过 cam_node，树莓派未连接)"
scp -q "$PI_HOST":'~/.config/systemd/user/vision-cam.service' \
    "$DEST/02-树莓派端/systemd/" 2>/dev/null || true

# ── 03 配置脚本 ────────────────────────────────────────────
cp -r "$PROJ/config/." "$DEST/03-配置脚本/"
cp "$PROJ/scripts/deploy.sh" "$PROJ/scripts/backup.sh" "$DEST/03-配置脚本/"
cp -r "$PROJ/scripts/setup" "$PROJ/scripts/tests" "$DEST/03-配置脚本/"

# ── 04 依赖资源 ────────────────────────────────────────────
scp -q "$HOST_HOST":'~/yolov8n.pt' "$DEST/04-依赖资源/" 2>/dev/null || echo "  (跳过 yolov8n.pt)"
{
    echo "=== 生成时间 ==="; date
    echo; echo "=== 主机 ==="
    ssh "$HOST_HOST" '. /etc/os-release; echo "OS: $PRETTY_NAME"; uname -r; echo "ROS: $(ls /opt/ros/)"; dpkg -l libopencv-dev 2>/dev/null | tail -1 | awk "{print \$2, \$3}"' 2>/dev/null
    echo "-- venv --"
    ssh "$HOST_HOST" '~/venv/bin/pip list 2>/dev/null | grep -Ei "^(torch|torchvision|ultralytics|opencv-python|numpy|fastapi|uvicorn)"' 2>/dev/null
    echo; echo "=== 树莓派 ==="
    ssh "$PI_HOST" '. /etc/os-release; echo "OS: $PRETTY_NAME"; uname -r; uname -m; echo "ROS: $(ls /opt/ros/)"; dpkg -l libopencv-dev v4l-utils 2>/dev/null | grep ^ii | awk "{print \$2, \$3}"' 2>/dev/null
} > "$DEST/04-依赖资源/依赖包版本清单.txt"

# ── 05 文档 ────────────────────────────────────────────────
cp "$PROJ/README.md" "$DEST/05-文档/" 2>/dev/null || true
cp -r "$PROJ/docs/." "$DEST/05-文档/"
cp "$PROJ/docs/环境配置清单.md" "$DEST/环境配置清单.md" 2>/dev/null || true

echo "--- 完成 ---"
du -sh "$DEST" 2>/dev/null
find "$DEST" -maxdepth 2 -type d | sed "s|$DEST|.|" | sort
