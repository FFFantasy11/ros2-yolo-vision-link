#!/usr/bin/env bash
# ============================================================================
# verify_env.sh — 环境自检：确认这台机器具备跑本项目的基本条件
#
#   bash scripts/setup/verify_env.sh          # 在主机上跑（含推理依赖检查）
#   bash scripts/setup/verify_env.sh --pi     # 在树莓派上跑（含摄像头检查）
#
# 不需要 sudo，可反复运行。每一项输出 [ OK ] / [FAIL] / [WARN]，
# 退出码 = 失败项数（0 表示可以开工）。
# ============================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
MODE="host"
[ "${1:-}" = "--pi" ] && MODE="pi"

PASS=0; FAIL=0; WARNS=()

ok()   { printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARNS+=("$1"); }
section() { printf '\n── %s ─────────────────────────────────────\n' "$1"; }

echo "============================================================"
echo " 项目环境自检（$MODE）"
echo " 项目目录: $PROJ"
echo "============================================================"

section "系统与 ROS 2"

v=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
case "$v" in
    *24.04*) ok "系统 $v" ;;
    *)       warn "系统是 $v（推荐 Ubuntu 24.04，其他版本 ROS 包可能不匹配）" ;;
esac

[ -f /opt/ros/jazzy/setup.bash ] && ok "ROS 2 Jazzy 已安装" \
    || bad "找不到 /opt/ros/jazzy（见 docs/环境配置清单.md 的安装步骤）"

for c in cmake g++ colcon; do
    if ! command -v "$c" > /dev/null 2>&1; then
        bad "缺少 $c"
        continue
    fi
    ver=$("$c" --version 2> /dev/null | head -1)
    ok "${ver:-$c 可用}"
done

if pkg-config --exists opencv4 2> /dev/null; then
    ok "OpenCV $(pkg-config --modversion opencv4)（含开发头文件）"
else
    bad "缺少 OpenCV 开发包：sudo apt install libopencv-dev"
fi

section "工程编译产物"

if [ -f "$PROJ/ros2_ws/install/setup.bash" ]; then
    ok "ros2_ws 已编译"
    if [ "$MODE" = "pi" ]; then
        [ -x "$PROJ/ros2_ws/install/vision_cam/lib/vision_cam/cam_node" ] \
            && ok "cam_node 存在" \
            || bad "cam_node 未编译（colcon build --packages-select vision_cam）"
    else
        [ -x "$PROJ/ros2_ws/install/vision_detect/lib/vision_detect/detect_node" ] \
            && ok "detect_node 存在" \
            || bad "detect_node 未编译（colcon build --packages-select vision_detect）"
        [ -x "$PROJ/ros2_ws/install/vision_probe/lib/vision_probe/probe_node" ] \
            && ok "probe_node 存在" \
            || warn "probe_node 未编译（可选，仅用于测链路）"
    fi
else
    bad "ros2_ws 尚未编译：cd ros2_ws && colcon build"
fi

section "配置与网络"

[ -f "$PROJ/config/wire.xml" ] \
    && ok "DDS 配置 config/wire.xml 就位" \
    || warn "缺少 config/wire.xml（deploy.sh 会放好；纯 WiFi 传输时可以不设）"

if ip -4 -o addr show scope global 2> /dev/null | grep -q '192\.168\.10\.'; then
    ok "有线直连地址：$(ip -4 -o addr show scope global | awk '/192\.168\.10\./ {print $2" "$4}' | head -1)"
else
    warn "没有 192.168.10.x 地址（未做网线直连；纯 WiFi 也能跑，但帧间隔更抖）"
fi

section "推理依赖（仅主机）"

if [ "$MODE" = "pi" ]; then
    echo "  树莓派不跑推理，跳过。"
else
    PY="${VISION_PYTHON:-$HOME/venv/bin/python3}"
    if [ -x "$PY" ]; then
        ok "Python 解释器 $PY"
        # 必须先 source ROS，rclpy 才在 PYTHONPATH 里
        missing=$(bash -c "source /opt/ros/jazzy/setup.bash 2>/dev/null; '$PY' - <<'PYEOF'
import importlib
for m in ('numpy', 'cv2', 'torch', 'ultralytics', 'fastapi', 'uvicorn', 'rclpy'):
    try:
        importlib.import_module(m)
    except Exception:
        print(m)
PYEOF
" 2> /dev/null)
        if [ -z "$missing" ]; then
            ok "numpy / cv2 / torch / ultralytics / fastapi / uvicorn / rclpy 均可导入"
        else
            bad "以下模块导入失败：$(echo $missing | tr '\n' ' ')"
        fi

        nv=$(bash -c "source /opt/ros/jazzy/setup.bash 2>/dev/null; '$PY' -c 'import numpy; print(numpy.__version__)'" 2> /dev/null)
        case "$nv" in
            1.*) ok "numpy $nv（必须锁在 1.x）" ;;
            *)   bad "numpy 版本是 $nv，必须是 1.x（cv2/torch 按 1.x 的 C-API 编译）" ;;
        esac
    else
        bad "找不到 $PY（用 VISION_PYTHON 指定；装法见 README）"
    fi

    if [ -f "$HOME/yolov8n.pt" ]; then
        ok "模型权重 ~/yolov8n.pt（$(du -h "$HOME/yolov8n.pt" | cut -f1)）"
    else
        warn "缺少 ~/yolov8n.pt：bash scripts/host/fetch_model.sh"
    fi
fi

section "摄像头（仅树莓派）"

if [ "$MODE" = "pi" ]; then
    if [ -e /dev/video0 ]; then
        ok "设备 /dev/video0 存在"
        id -nG 2> /dev/null | grep -qw video && ok "当前用户在 video 组" \
            || bad "不在 video 组：sudo usermod -aG video \$USER 然后重新登录"
        if command -v v4l2-ctl > /dev/null 2>&1; then
            ok "v4l2-ctl 已安装"
            v4l2-ctl -d /dev/video0 --list-formats-ext 2> /dev/null | grep -q YUYV \
                && ok "支持 YUYV 格式" \
                || warn "未检测到 YUYV，采集参数里的 fourcc 需要改"
        else
            warn "缺 v4l2-ctl：sudo apt install v4l-utils"
        fi
        if command -v vcgencmd > /dev/null 2>&1; then
            t=$(vcgencmd get_throttled)
            case "$t" in
                *throttled=0x0*) ok "供电正常（$t）" ;;
                *) warn "供电/降频告警：$t（建议用官方 27W 电源）" ;;
            esac
        fi
    else
        bad "没有 /dev/video0（摄像头未插好或未上电）"
    fi
fi

echo
echo "============================================================"
printf " 汇总：通过 %d 项 ｜ 失败 %d 项 ｜ 警告 %d 项\n" "$PASS" "$FAIL" "${#WARNS[@]}"
echo "============================================================"

[ "$FAIL" -eq 0 ] && echo " 硬性检查全部通过。" || echo " 有 $FAIL 项未通过，先解决它们再启动。"

if [ "${#WARNS[@]}" -gt 0 ]; then
    echo
    echo " 需要留意："
    for w in "${WARNS[@]}"; do echo "   - $w"; done
fi

exit "$FAIL"
