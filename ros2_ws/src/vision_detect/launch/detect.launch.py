"""启动主机端检测节点。

为什么不能用 ros2 launch 直接起：
    节点依赖 venv 里的 ultralytics/torch，而 ros2 的可执行脚本写死了
    系统 python3 的 shebang。这里显式用 venv 解释器执行已安装的脚本。
"""
import os

from ament_index_python.packages import get_package_prefix, get_package_share_directory
from launch import LaunchDescription
from launch.actions import ExecuteProcess, DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    python_exe = LaunchConfiguration('python_exe')
    params = os.path.join(
        get_package_share_directory('vision_detect'), 'config', 'detect.yaml'
    )
    exe = os.path.join(
        get_package_prefix('vision_detect'), 'lib', 'vision_detect', 'detect_node'
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            'python_exe',
            default_value=os.environ.get('VISION_PYTHON', os.path.expanduser('~/venv/bin/python3')),
            description='带 ultralytics/torch 的解释器（可用 VISION_PYTHON 环境变量覆盖）',
        ),
        ExecuteProcess(
            cmd=[python_exe, exe, '--ros-args', '--params-file', params],
            output='screen',
        ),
    ])
