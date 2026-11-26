// 链路探针：只统计，不推理、不显示。
// 回答一个问题：这条链路到底能跑多快、抖不抖、延迟多少。
//
// 用法：
//   ros2 run vision_probe probe_node                    # 一直跑，Ctrl-C 看汇总
//   ros2 run vision_probe probe_node --ros-args -p seconds:=30.0
//   ros2 run vision_probe probe_node --ros-args -p topic:=/image_raw/compressed
//
// 注意：延迟那一列含两台机器的时钟偏差。两台都对过时（主机当 NTP、Pi 同步过来）
// 误差 <1ms，可以直接信；Pi 只连网线且网关留空时没有时间源，只能看相对变化。
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <deque>
#include <string>
#include <vector>

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

namespace vision_probe
{

class ProbeNode : public rclcpp::Node
{
public:
  ProbeNode()
  : rclcpp::Node("vision_probe")
  {
    topic_ = declare_parameter<std::string>("topic", "/image_raw/compressed");
    seconds_ = declare_parameter<double>("seconds", 0.0);

    rclcpp::QoS qos(rclcpp::KeepLast(1));
    qos.best_effort();
    sub_ = create_subscription<sensor_msgs::msg::CompressedImage>(
      topic_, qos,
      [this](sensor_msgs::msg::CompressedImage::SharedPtr msg) {on_msg(*msg);});

    t_win_ = std::chrono::steady_clock::now();
    printf("订阅 %s … Ctrl-C 结束\n\n", topic_.c_str());
  }

  double seconds() const {return seconds_;}

  void maybe_report(double elapsed)
  {
    const double dt = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - t_win_).count();
    if (dt < 1.0) {
      return;
    }
    const double fps = win_n_ / dt;
    const double mbps = win_bytes_ * 8.0 / dt / 1e6;
    const double kb = win_n_ ? win_bytes_ / win_n_ / 1024.0 : 0.0;
    printf(
      "[%6.1fs] %5.1f fps | %6.1f Mbps | %6.1f KB/帧 | 间隔p95 %5.1f ms | "
      "延迟p50 %6.1f ms | 卡顿 %ld\n",
      elapsed, fps, mbps, kb, pct(gaps_, 0.95) * 1000.0, pct(lat_, 0.50) * 1000.0,
      static_cast<long>(stalls_));
    fflush(stdout);
    win_n_ = 0;
    win_bytes_ = 0;
    t_win_ = std::chrono::steady_clock::now();
  }

  void summary(double elapsed)
  {
    printf("\n%s\n", std::string(62, '=').c_str());
    if (total_n_ == 0) {
      printf("一帧都没收到。先确认：Pi 上 /image_raw/compressed 有发布者吗？\n");
      printf("  ros2 topic info /image_raw/compressed -v\n");
      printf("  两端 ROS_DOMAIN_ID 是否一致？网线是否通？FASTRTPS 配置是否一致？\n");
      return;
    }
    const double dur = std::max(elapsed, 1e-6);
    printf("总帧数      %ld   用时 %.1fs\n", static_cast<long>(total_n_), dur);
    printf("平均帧率    %.1f fps\n", total_n_ / dur);
    printf("平均带宽    %.1f Mbps\n", total_bytes_ * 8.0 / dur / 1e6);
    printf("平均帧大小  %.1f KB\n", total_bytes_ / total_n_ / 1024.0);
    printf(
      "帧间隔      p50 %.1f / p95 %.1f / p99 %.1f ms\n",
      pct(gaps_, 0.50) * 1000.0, pct(gaps_, 0.95) * 1000.0, pct(gaps_, 0.99) * 1000.0);
    printf(
      "端到端延迟  p50 %.1f / p95 %.1f ms  (含两机时钟偏差)\n",
      pct(lat_, 0.50) * 1000.0, pct(lat_, 0.95) * 1000.0);
    printf("卡顿次数    %ld  (>200ms 的间隔)\n", static_cast<long>(stalls_));
    printf("%s\n", std::string(62, '=').c_str());
  }

private:
  void on_msg(const sensor_msgs::msg::CompressedImage & msg)
  {
    const auto now = std::chrono::steady_clock::now();
    const double size = static_cast<double>(msg.data.size());

    if (has_last_) {
      const double gap = std::chrono::duration<double>(now - last_t_).count();
      push(gaps_, gap);
      if (gap > 0.2) {
        ++stalls_;
      }
    }
    last_t_ = now;
    has_last_ = true;

    ++total_n_;
    total_bytes_ += size;
    ++win_n_;
    win_bytes_ += size;

    const double stamp = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9;
    if (stamp > 0.0) {
      const double now_s = std::chrono::duration<double>(
        std::chrono::system_clock::now().time_since_epoch()).count();
      push(lat_, now_s - stamp);
    }
  }

  static void push(std::deque<double> & d, double v)
  {
    if (d.size() >= 2000) {
      d.pop_front();
    }
    d.push_back(v);
  }

  static double pct(const std::deque<double> & d, double p)
  {
    if (d.empty()) {
      return 0.0;
    }
    std::vector<double> v(d.begin(), d.end());
    const std::size_t k = std::min(v.size() - 1,
        static_cast<std::size_t>(p * static_cast<double>(v.size())));
    std::nth_element(v.begin(), v.begin() + static_cast<long>(k), v.end());
    return v[k];
  }

  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr sub_;
  std::string topic_;
  double seconds_{0.0};

  long total_n_{0};
  double total_bytes_{0.0};
  long stalls_{0};
  std::deque<double> gaps_;
  std::deque<double> lat_;

  long win_n_{0};
  double win_bytes_{0.0};
  std::chrono::steady_clock::time_point t_win_;

  std::chrono::steady_clock::time_point last_t_;
  bool has_last_{false};
};

}  // namespace vision_probe

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  auto node = std::make_shared<vision_probe::ProbeNode>();
  rclcpp::executors::SingleThreadedExecutor ex;
  ex.add_node(node);

  const auto t0 = std::chrono::steady_clock::now();
  while (rclcpp::ok()) {
    ex.spin_once(std::chrono::milliseconds(20));
    const double elapsed =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    node->maybe_report(elapsed);
    if (node->seconds() > 0.0 && elapsed >= node->seconds()) {
      break;
    }
  }
  const double elapsed =
    std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  node->summary(elapsed);

  rclcpp::shutdown();
  return 0;
}
