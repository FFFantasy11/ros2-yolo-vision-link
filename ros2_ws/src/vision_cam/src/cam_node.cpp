// 树莓派端采集节点：V4L2 -> JPEG -> sensor_msgs/CompressedImage
//
// 设计要点（每一条都是实测换来的，改动前请先读注释）：
//   1) 只发压缩图，QoS 用 BEST_EFFORT + KEEP_LAST(1)。
//      旧方案 usb_cam 用 RELIABLE + depth 100，640x480 YUYV 一帧 600KB，
//      100 帧历史 = 61MB，下游一慢就积压，端到端延迟从 950ms 涨到 1177ms。
//      宁可丢帧也绝不排队，这是实时视频唯一正确的取舍。
//   2) --buffers 必须 > 1：单缓冲下驱动要等缓冲区回收才能重新入队，
//      实测 1 -> 10.1fps，4 -> 19.9fps，8 -> 19.9fps，取 4 兼顾延迟。
//   3) FOURCC 必须在宽高之前设，否则驱动可能锁到别的格式上。
//   4) 打开设备会把控件恢复成默认值，必须在 open 之后重新锁死（见 v4l2_controls.hpp）。
//   5) 这个模组 MJPG 上限只有 10fps，YUYV 才能到 20fps，所以默认 YUYV。

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/videoio.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

#include "vision_cam/v4l2_controls.hpp"

namespace vision_cam
{

class CamNode : public rclcpp::Node
{
public:
  CamNode()
  : rclcpp::Node("vision_cam")
  {
    device_ = declare_parameter<std::string>("device", "/dev/video0");
    topic_ = declare_parameter<std::string>("topic", "/image_raw/compressed");
    width_ = declare_parameter<int>("width", 640);
    height_ = declare_parameter<int>("height", 480);
    fps_ = declare_parameter<double>("fps", 20.0);
    fourcc_ = declare_parameter<std::string>("fourcc", "YUYV");
    quality_ = declare_parameter<int>("quality", 80);
    frame_id_ = declare_parameter<std::string>("frame_id", "camera_optical_frame");
    buffers_ = declare_parameter<int>("buffers", 4);
    print_every_ = declare_parameter<int>("print_every", 40);
    lock_controls_ = declare_parameter<bool>("lock_controls", true);
    exposure_ = declare_parameter<int>("exposure", 100);
    gain_ = declare_parameter<int>("gain", 63);
    brightness_ = declare_parameter<int>("brightness", 0);

    // BEST_EFFORT + depth 1：允许丢帧，禁止排队。
    rclcpp::QoS qos(rclcpp::KeepLast(1));
    qos.best_effort();
    pub_ = create_publisher<sensor_msgs::msg::CompressedImage>(topic_, qos);
  }

  bool open_camera()
  {
    if (fourcc_.size() != 4) {
      RCLCPP_ERROR(get_logger(), "fourcc 必须是 4 个字符，收到 \"%s\"", fourcc_.c_str());
      return false;
    }

    cap_.open(device_, cv::CAP_V4L2);
    if (!cap_.isOpened()) {
      RCLCPP_ERROR(get_logger(), "打不开摄像头 %s", device_.c_str());
      return false;
    }

    // 顺序不可调换：FOURCC -> 宽 -> 高 -> fps -> 缓冲数
    cap_.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc(
        fourcc_[0], fourcc_[1], fourcc_[2], fourcc_[3]));
    cap_.set(cv::CAP_PROP_FRAME_WIDTH, width_);
    cap_.set(cv::CAP_PROP_FRAME_HEIGHT, height_);
    cap_.set(cv::CAP_PROP_FPS, fps_);
    cap_.set(cv::CAP_PROP_BUFFERSIZE, buffers_);

    // 驱动会给出它实际接受的格式，不以参数为准，以回读为准
    const int w = static_cast<int>(cap_.get(cv::CAP_PROP_FRAME_WIDTH));
    const int h = static_cast<int>(cap_.get(cv::CAP_PROP_FRAME_HEIGHT));
    const double real_fps = cap_.get(cv::CAP_PROP_FPS);

    if (lock_controls_) {
      V4l2ControlSet ctl;
      ctl.exposure = exposure_;
      ctl.gain = gain_;
      ctl.brightness = brightness_;
      const int n = apply_controls(device_, ctl);
      RCLCPP_INFO(get_logger(), "已下发 %d 个控件（曝光 %d x100µs、增益 %d）", n, exposure_, gain_);
      if (n < 0) {
        RCLCPP_WARN(get_logger(), "控件未下发，暗光下可能自动降帧到 10fps");
      }
    }

    RCLCPP_INFO(
      get_logger(), "%s %s %dx%d @%.1ffps -> %s (q%d, buffers %d)", device_.c_str(),
      fourcc_.c_str(), w, h, real_fps, topic_.c_str(), quality_, buffers_);
    if (w != width_ || h != height_) {
      RCLCPP_WARN(
        get_logger(), "驱动实际分辨率 %dx%d 与请求 %dx%d 不一致", w, h, width_, height_);
    }
    return true;
  }

  /// 主循环：阻塞在 cap_.read() 上，由摄像头节奏驱动，不做额外 sleep。
  void run()
  {
    std::vector<uchar> buf;
    buf.reserve(64 * 1024);
    const std::vector<int> jpeg_params{cv::IMWRITE_JPEG_QUALITY, quality_};

    int64_t n = 0;
    int64_t fail = 0;
    auto t0 = std::chrono::steady_clock::now();

    while (rclcpp::ok()) {
      cv::Mat frame;
      if (!cap_.read(frame) || frame.empty()) {
        if (++fail % 100 == 1) {
          RCLCPP_WARN(get_logger(), "取帧失败（累计 %ld 次）", static_cast<long>(fail));
        }
        continue;
      }

      if (!cv::imencode(".jpg", frame, buf, jpeg_params)) {
        RCLCPP_WARN(get_logger(), "JPEG 编码失败");
        continue;
      }

      sensor_msgs::msg::CompressedImage msg;
      msg.header.stamp = now();
      msg.header.frame_id = frame_id_;
      msg.format = "jpeg";
      msg.data.assign(buf.begin(), buf.end());
      pub_->publish(msg);

      ++n;
      if (print_every_ > 0 && n % print_every_ == 0) {
        const double dt =
          std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        RCLCPP_INFO(
          get_logger(), "%ld 帧 | %5.1f fps | %5.1f KB/帧", static_cast<long>(n),
          n / dt, buf.size() / 1024.0);
      }
    }
  }

private:
  cv::VideoCapture cap_;
  rclcpp::Publisher<sensor_msgs::msg::CompressedImage>::SharedPtr pub_;

  std::string device_;
  std::string topic_;
  std::string fourcc_;
  std::string frame_id_;
  int width_{640};
  int height_{480};
  int quality_{80};
  int buffers_{4};
  int print_every_{40};
  int exposure_{100};
  int gain_{63};
  int brightness_{0};
  double fps_{20.0};
  bool lock_controls_{true};
};

}  // namespace vision_cam

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<vision_cam::CamNode>();

  if (!node->open_camera()) {
    rclcpp::shutdown();
    return 1;
  }
  node->run();

  rclcpp::shutdown();
  return 0;
}
