#!/bin/bash
# 一键把项目同步到两台机器（并按需编译）
#
# 在 Windows 的 Git Bash 里运行（依赖 ssh/scp/tar，Git for Windows 自带）：
#   bash scripts/deploy.sh pi            只同步树莓派
#   bash scripts/deploy.sh host          只同步主机
#   bash scripts/deploy.sh all           两端都同步
#   bash scripts/deploy.sh all --build   同步并重新编译
#
# 为什么用 tar 管道而不是 scp -r：
#   scp -r src host:已有/src/ 会把 src 再套一层成 src/src。
#   tar 管道只会覆盖同名文件，不会产生嵌套目录。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
TARGET="${1:-all}"
BUILD="${2:-}"

# 两台机器怎么连：优先用环境变量，其次用 ~/.ssh/config 里的别名
#   PI_HOST=pi@192.168.10.2 HOST_HOST=me@192.168.1.20 bash scripts/deploy.sh all --build
PI_HOST="${PI_HOST:-pi}"
HOST_HOST="${HOST_HOST:-host}"

sync_one() {
    local ssh_host="$1" wire="$2" pkgs="${3:-}"

    echo "==> 同步到 $ssh_host"
    tar -C "$PROJ" -cf - ros2_ws/src scripts config docs \
        | ssh "$ssh_host" 'mkdir -p ~/vision_project && tar -C ~/vision_project -xf -'

    # 两端有线口 IP 不同，各自的 DDS 白名单不能混用
    ssh "$ssh_host" "cp ~/vision_project/config/wire-$wire.xml ~/vision_project/config/wire.xml \
        && chmod +x ~/vision_project/scripts/*/*.sh ~/vision_project/scripts/tests/*.py 2>/dev/null || true"
    echo "    wire.xml <- wire-$wire.xml"

    if [ "$BUILD" = "--build" ]; then
        echo "==> 编译 $ssh_host ($pkgs)"
        ssh "$ssh_host" "cd ~/vision_project/ros2_ws && source /opt/ros/jazzy/setup.bash && colcon build --packages-select $pkgs --cmake-args -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -8"
    fi
}

case "$TARGET" in
    # sync_one <ssh目标> <DDS配置后缀> <要编译的包>
    pi)   sync_one "$PI_HOST"   pi   vision_cam ;;
    host) sync_one "$HOST_HOST" host "vision_detect vision_probe" ;;
    all)
        sync_one "$PI_HOST"   pi   vision_cam
        sync_one "$HOST_HOST" host "vision_detect vision_probe"
        ;;
    *)
        echo "用法: PI_HOST=<pi 的 ssh 别名> HOST_HOST=<主机 ssh 别名> bash $0 {pi|host|all} [--build]"
        exit 1
        ;;
esac

echo "完成"
