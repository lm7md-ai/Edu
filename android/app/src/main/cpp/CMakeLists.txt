cmake_minimum_required(VERSION 3.22.1)
project(edu_tutor_runtime LANGUAGES CXX)

add_library(edu_tutor_runtime SHARED edu_tutor_runtime.cpp)
target_compile_features(edu_tutor_runtime PRIVATE cxx_std_17)
target_include_directories(edu_tutor_runtime PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(edu_tutor_runtime PRIVATE dl log)
