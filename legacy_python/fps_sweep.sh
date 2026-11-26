#!/usr/bin/env bash
# 帧率扫描：固定手动曝光，测不同分辨率 / 不同设定点的实际帧率
#
# 目的：判断 20fps 这个上限来自哪里
#   [A] 同一设定点 30fps，换分辨率
#       → 只有 720p/1600x1200 卡 20、640x480 能到 30 = 带宽/等时传输档位问题
#       → 所有分辨率都卡 20                  = 模组固件的全局上限
#   [B] 720p 下换设定点
#       → 5/10/15 能如实给 = 相机服从低帧率设定，20 是它的真实天花板
#       → 全是 20          = 设定点被完全忽略
#
# 用法： bash fps_sweep.sh              # 默认每个组合采 120 帧
#        FRAMES=60 bash fps_sweep.sh    # 更快，精度略降
#        DEV=/dev/video2 bash fps_sweep.sh

set -u

DEV="${DEV:-/dev/v4l/by-id/usb-camera_camera_0012309087-video-index0}"
[ -e "$DEV" ] || DEV=/dev/video0
FRAMES="${FRAMES:-120}"

# 一次调用内同时下发控件和格式，避免设备关闭后驱动把设置还原成默认值
CTRLS="exposure_dynamic_framerate=0,auto_exposure=1,exposure_time_absolute=30,gain=63"

if [ ! -e "$DEV" ]; then
  echo "找不到设备 $DEV"
  v4l2-ctl --list-devices 2>/dev/null
  exit 1
fi

one() {
  local w=$1 h=$2 r=$3 t0 t1 ms
  t0=$(date +%s%N)
  sudo v4l2-ctl -d "$DEV" \
    --set-ctrl="$CTRLS" \
    --set-fmt-video="width=$w,height=$h,pixelformat=MJPG" \
    --set-parm="$r" \
    --stream-mmap=4 --stream-count="$FRAMES" >/dev/null 2>&1
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  awk -v w="$w" -v h="$h" -v r="$r" -v m="$ms" -v f="$FRAMES" 'BEGIN{
    if (m <= 0) { printf "  %-10s  set=%-3s  测量失败\n", w"x"h, r; exit }
    printf "  %-10s  set=%-3s  %6.2f fps   (%d ms / %d 帧)\n", w"x"h, r, f*1000.0/m, m, f
  }'
}

echo "设备    $DEV"
echo "固定    exposure_time_absolute=30 (3ms)   gain=63   dynamic_framerate=0"
echo "采样    每组 $FRAMES 帧"
echo

echo "[A] 设定点固定 30fps，换分辨率"
for res in "1280 720" "640 480" "800 600" "1600 1200"; do
  one $res 30
done
echo

echo "[B] 分辨率固定 1280x720，换设定点"
for r in 5 10 15 20 30; do
  one 1280 720 "$r"
done
echo

echo "[C] 视频与麦克风带宽竞争检查"
echo -n "  音频接口是否被占用: "
if sudo fuser /dev/snd/* >/dev/null 2>&1; then
  echo "是（会抢等时带宽，关掉录音程序再测）"
  sudo fuser -v /dev/snd/* 2>&1 | sed 's/^/    /'
else
  echo "否"
fi
echo -n "  USB 链路: "
lsusb -t 2>/dev/null | grep -i 'uvcvideo' | head -1
echo
echo "完成。判读见脚本头部注释。"
