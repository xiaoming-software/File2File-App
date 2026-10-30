cmake_minimum_required(VERSION 3.22.1)
project(webrpc_sendfile_async)

set(_jni_dir "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
set(_webrpc_so "${_jni_dir}/libwebrpc.so")

# Flutter/AGP may still configure cmake for x86_64 even when abiFilters are
# arm-only. We only have libwebrpc.so for arm64-v8a + armeabi-v7a.
if(NOT EXISTS "${_webrpc_so}")
  message(STATUS
    "webrpc_sendfile_async: no libwebrpc.so for ${ANDROID_ABI}, building stub")
  add_library(webrpc_sendfile_async SHARED webrpc_sendfile_async_stub.c)
  return()
endif()

add_library(webrpc_sendfile_async SHARED
    ../../../../../webrpc-sdk/webrpc_sendfile_async.c)

find_library(log-lib log)

# Link via -L/-l so DT_NEEDED is "libwebrpc.so", NOT the host absolute path
# (IMPORTED_LOCATION alone embeds the build-machine path and breaks dlopen
# on device).
target_link_directories(webrpc_sendfile_async PRIVATE "${_jni_dir}")
target_link_libraries(webrpc_sendfile_async webrpc ${log-lib})
