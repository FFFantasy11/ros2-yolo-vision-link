cmake_minimum_required(VERSION 3.16)
project(vision_cam CXX)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)
endif()

if(CMAKE_COMPILER_IS_GNUCXX)
  add_compile_options(-O2 -Wall -Wextra -Wno-unused-parameter)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs videoio)

add_executable(cam_node
  src/cam_node.cpp
  src/v4l2_controls.cpp
)
target_include_directories(cam_node PRIVATE
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  ${OpenCV_INCLUDE_DIRS}
)
target_link_libraries(cam_node
  rclcpp::rclcpp
  ${sensor_msgs_TARGETS}
  ${OpenCV_LIBS}
)

install(TARGETS cam_node DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch config
  DESTINATION share/${PROJECT_NAME}
)

ament_package()
