#!/usr/bin/env bash
# 阶段 1：树莓派端出流（usb_cam 采集 + republish 压成 JPEG）
#
# 这套配置是在你的机器上实测跑通的，换别的组合会踩坑，原因见下：
#   1) v4l2_camera 不支持 MJPG 输入 → cv_bridge 抛 "Unrecognized image encoding []" 后 abort
#   2) usb_cam 的 pixel_format:=raw_mjpeg / mjpeg2rgb → Segmentation fault
#   3) usb_cam 的 pixel_format:=yuyv → 正常，640x480 稳定 20fps，抖动标准差 2ms
#   4) usb_cam 只接受 /dev/videoN，传 /dev/v4l/by-id/... 会被拼成 /dev/../../video0 报错
#   5) YUYV 下 1280x720 只有 10fps，640x480 才有 20fps，所以默认用 640x480
#
# 用法：
#   bash start_camera.sh
#   QUALITY=70 bash start_camera.sh
#   WIDTH=800 HEIGHT=600 bash start_camera.sh
#   DEV=/dev/video2 bash start_camera.sh

# 注意：不能用 set -u。ROS 的 setup.bash 会引用未定义变量（AMENT_TRACE_SETUP_FILES），一开 -u 就退出
set -o pipefail
source /opt/ros/jazzy/setup.bash

# 在 /sys/class/video4linux 里找名字是 camera 且支持格式枚举的那个节点
find_cam() {
  local d n
  for d in $(ls -d /sys/class/video4linux/video* 2>/dev/null | sort -V); do
    n="/dev/$(basename "$d")"
    [ "$(cat "$d/name" 2>/dev/null)" = "camera: camera" ] || continue
    if v4l2-ctl -d "$n" --list-formats 2>/dev/null | grep -q YUYV; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

if [ -z "${DEV:-}" ]; then
  DEV="$(find_cam)" || DEV="/dev/video0"
fi
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
FPS="${FPS:-30}"
QUALITY="${QUALITY:-80}"
EXPOSURE="${EXPOSURE:-30}"   # 单位 100µs，30 = 3ms
GAIN="${GAIN:-63}"

if [ ! -e "$DEV" ]; then
  echo "找不到设备 $DEV"
  v4l2-ctl --list-devices 2>/dev/null || true
  exit 1
fi

# 关闭"允许降帧率"，锁死手动曝光与增益：输入必须稳定，否则 YOLO 的框会随亮度跳
apply_ctrls() {
  v4l2-ctl -d "$DEV" \
    --set-ctrl=exposure_dynamic_framerate=0 \
    --set-ctrl=auto_exposure=1 \
    --set-ctrl=exposure_time_absolute="$EXPOSURE" \
    --set-ctrl=gain="$GAIN" \
    --set-ctrl=brightness=0 2>/dev/null \
  || echo "  (控件设置跳过：权限不足或设备忙)"
}

echo "=== 采集参数 ==="
echo "  设备      $DEV"
echo "  分辨率    ${WIDTH}x${HEIGHT}   YUYV"
echo "  帧率设定  ${FPS} fps"
echo "  压缩      JPEG q${QUALITY} -> /image_raw/compressed"
echo "  曝光      ${EXPOSURE} (x100us)   增益 ${GAIN}"
echo

apply_ctrls

ros2 run usb_cam usb_cam_node_exe --ros-args \
  -p video_device:="$DEV" \
  -p image_width:="$WIDTH" \
  -p image_height:="$HEIGHT" \
  -p framerate:="$FPS.0" \
  -p pixel_format:=yuyv \
  -p io_method:=mmap \
  -p brightness:=0 \
  -p frame_id:=camera_optical_frame &
CAM_PID=$!

sleep 2

ros2 run image_transport republish raw compressed --ros-args \
  -p jpeg_quality:="$QUALITY" \
  -r in:=/image_raw \
  -r out:=/image_raw &
REPUB_PID=$!

cleanup() {
  echo
  echo "-- 停止 --"
  kill "$REPUB_PID" "$CAM_PID" 2>/dev/null
  sleep 0.5
  kill -9 "$REPUB_PID" "$CAM_PID" 2>/dev/null
  wait 2>/dev/null
  echo "已退出"
}
trap cleanup INT TERM

sleep 2
# usb_cam 启动时会用默认值重写控件（实测把 brightness 改成 50），所以再设一次
apply_ctrls

echo "-- 已发布的话题 --"
ros2 topic list 2>/dev/null | grep -i image || echo "  (还没出现 image 话题)"
echo
echo "另一个终端可以跑："
echo "  ros2 topic hz /image_raw/compressed"
echo "  ros2 topic bw /image_raw/compressed"
echo
echo "Ctrl-C 停止。"

wait
