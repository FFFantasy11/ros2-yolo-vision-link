#include "vision_cam/v4l2_controls.hpp"

#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <utility>
#include <vector>

#include <rclcpp/logging.hpp>

namespace vision_cam
{
namespace
{

/// 单控件写入。返回 0 成功，否则返回 errno 方便定位（EINVAL = 该模组没有这个控件）。
int set_ctrl(int fd, uint32_t id, int32_t value)
{
  v4l2_control c{};
  c.id = id;
  c.value = value;
  if (::ioctl(fd, VIDIOC_S_CTRL, &c) == 0) {
    return 0;
  }
  return errno == 0 ? -1 : errno;
}

/// 写入并回读，确认驱动真的接受了这个值（有些驱动会静默截断到合法范围）。
bool get_ctrl(int fd, uint32_t id, int32_t * out)
{
  v4l2_control c{};
  c.id = id;
  if (::ioctl(fd, VIDIOC_G_CTRL, &c) != 0) {
    return false;
  }
  *out = c.value;
  return true;
}

}  // namespace

int apply_controls(const std::string & device, const V4l2ControlSet & ctl)
{
  // 单独开一个只用于 ioctl 的 fd：VideoCapture 不暴露内部描述符，
  // 而 V4L2 控件是设备级状态，第二个 fd 写入同样生效。
  const int fd = ::open(device.c_str(), O_RDWR | O_NONBLOCK);
  if (fd < 0) {
    RCLCPP_WARN(
      rclcpp::get_logger("vision_cam"), "打开 %s 失败（%s），跳过控件下发",
      device.c_str(), std::strerror(errno));
    return -1;
  }

  std::vector<std::pair<uint32_t, int32_t>> plan;
  if (ctl.dynamic_framerate_off) {
    plan.emplace_back(V4L2_CID_EXPOSURE_AUTO_PRIORITY, 0);
  }
  if (ctl.manual_exposure) {
    plan.emplace_back(V4L2_CID_EXPOSURE_AUTO, V4L2_EXPOSURE_MANUAL);
  }
  if (ctl.exposure >= 0) {
    plan.emplace_back(V4L2_CID_EXPOSURE_ABSOLUTE, ctl.exposure);
  }
  if (ctl.gain >= 0) {
    plan.emplace_back(V4L2_CID_GAIN, ctl.gain);
  }
  plan.emplace_back(V4L2_CID_BRIGHTNESS, ctl.brightness);

  int ok = 0;
  for (const auto & [id, value] : plan) {
    const int rc = set_ctrl(fd, id, value);
    if (rc != 0) {
      RCLCPP_WARN(
        rclcpp::get_logger("vision_cam"), "控件 0x%08x 写入 %d 失败：%s",
        id, value, rc == EINVAL ? "该模组不支持此控件" : std::strerror(rc));
      continue;
    }
    int32_t back = 0;
    if (get_ctrl(fd, id, &back) && back != value) {
      RCLCPP_WARN(
        rclcpp::get_logger("vision_cam"), "控件 0x%08x 被驱动截断：期望 %d 实际 %d",
        id, value, back);
    }
    ++ok;
  }
  ::close(fd);
  return ok;
}

}  // namespace vision_cam
