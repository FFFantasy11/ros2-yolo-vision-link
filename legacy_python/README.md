# legacy_python —— 旧实现存档

这里的文件**不参与运行**，仅用于对照与追溯。当前运行的节点在 `../ros2_ws/src/`。

| 文件 | 状态 | 说明 |
|---|---|---|
| `cam_pub.py` | 已被取代 | → `vision_cam/cam_node.cpp`（C++）。参数与行为等价 |
| `probe.py` | 已被取代 | → `vision_probe/probe_node.cpp`（C++） |
| `web_server.py` | 已被取代 | → `vision_detect`（ament_python 包），参数改走 ROS 参数 |
| `web_ctl.sh` | 已被取代 | → `scripts/host/start_detect.sh` / `stop_detect.sh` |
| `start_cam_pub.sh` | 已被取代 | → `scripts/pi/start_cam.sh` + systemd 单元 |
| `yolo_view.py` | **已废弃** | 与 `vision_detect` 推理链路重复，本地预览价值被网页端覆盖 |
| `start_camera.sh` | **已废弃** | usb_cam 方案，实测 RELIABLE+depth100 积压导致 956ms 延迟 |
| `fps_sweep.sh` | **已废弃** | 一次性帧率上限实验，结论已固化进 `cam.yaml` 默认值 |

想彻底清理冗余，删掉整个 `legacy_python/` 即可，不影响任何运行路径。
