cmake_minimum_required(VERSION 3.16)
project(vision_probe CXX)

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

add_executable(probe_node src/probe_node.cpp)
target_link_libraries(probe_node
  rclcpp::rclcpp
  ${sensor_msgs_TARGETS}
)

install(TARGETS probe_node DESTINATION lib/${PROJECT_NAME})

ament_package()
