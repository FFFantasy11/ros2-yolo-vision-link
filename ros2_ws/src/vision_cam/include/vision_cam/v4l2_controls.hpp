// V4L2 控件直写（替代对 v4l2-ctl 命令行的 subprocess 调用）。
//
// 为什么必须锁控件：
//   1) cv::VideoCapture::open() 会把所有控件恢复成驱动默认值，其中
//      exposure_dynamic_framerate 默认允许"动态降帧"。暗光下自动曝光把积分时间
//      拉到 100ms，帧率立刻从 20fps 掉到 10fps —— 这是阶段一踩过的坑。
//   2) 必须在 open 之后、开始取流之前下发，顺序也不能变：先允许手动曝光，
//      再写曝光时间，否则写进去的值会被自动曝光立刻覆盖。
//
// 为什么用 ioctl 而不是 system("v4l2-ctl ...")：
//   少一个 fork/exec、少一个外部依赖（v4l-utils 只用于自检脚本），
//   且能拿到每个控件的真实写入结果，失败时能明确报出是哪个控件。
#ifndef VISION_CAM__V4L2_CONTROLS_HPP_
#define VISION_CAM__V4L2_CONTROLS_HPP_

#include <string>

namespace vision_cam
{

/// 需要下发的控件集合。负值表示"该控件不改"，用于某些没有 gain 的模组。
struct V4l2ControlSet
{
  bool dynamic_framerate_off{true};  ///< exposure_dynamic_framerate = 0，禁止自动降帧
  bool manual_exposure{true};        ///< auto_exposure = 1 (Manual Mode)
  int exposure{100};                 ///< exposure_time_absolute，单位 100µs，100 = 10ms
  int gain{63};                      ///< gain，0~63
  int brightness{0};                 ///< brightness，-128~127
};

/// 把控件逐个写到设备。
/// @return 成功下发的控件个数；设备打不开时返回 -1。
int apply_controls(const std::string & device, const V4l2ControlSet & ctl);

}  // namespace vision_cam

#endif  // VISION_CAM__V4L2_CONTROLS_HPP_
