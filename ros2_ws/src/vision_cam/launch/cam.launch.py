from launch import LaunchDescription
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare
from launch.substitutions import PathJoinSubstitution


def generate_launch_description():
    # 手动调试用：ros2 launch vision_cam cam.launch.py
    # 开机自启不走 launch，直接由 systemd 调可执行文件（少一层 python 解释器）
    params = PathJoinSubstitution(
        [FindPackageShare('vision_cam'), 'config', 'cam.yaml']
    )
    return LaunchDescription([
        Node(
            package='vision_cam',
            executable='cam_node',
            name='vision_cam',
            output='screen',
            parameters=[params],
        ),
    ])
