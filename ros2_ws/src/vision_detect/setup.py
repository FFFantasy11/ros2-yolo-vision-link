from setuptools import setup

package_name = 'vision_detect'

setup(
    name=package_name,
    version='1.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/config', ['config/detect.yaml']),
        ('share/' + package_name + '/launch', ['launch/detect.launch.py']),
        ('share/' + package_name + '/web', ['web/index.html']),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='FFFantasy11',
    maintainer_email='FFFantasy11@users.noreply.github.com',
    description='YOLOv8 实时检测 + 网页推流节点',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'detect_node = vision_detect.detect_node:main',
        ],
    },
)
