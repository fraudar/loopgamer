cmake_minimum_required(VERSION 3.22.1)
project(libretro_jni VERSION 1.0.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(libretro_jni SHARED
    libretro_jni.cpp
    libretro_vulkan.cpp
)

find_library(android-lib android)
find_library(log-lib log)
find_library(egl-lib EGL)
find_library(gles2-lib GLESv2)

if(ANDROID_ABI STREQUAL "arm64-v8a")
    add_subdirectory(third_party/libadrenotools)
    target_compile_definitions(libretro_jni PRIVATE LOOPGAMER_HAS_ADRENOTOOLS=1)
    target_link_libraries(libretro_jni
        adrenotools
        ${android-lib}
        ${log-lib}
        ${egl-lib}
        ${gles2-lib}
        dl
    )
else()
    target_link_libraries(libretro_jni
        ${android-lib}
        ${log-lib}
        ${egl-lib}
        ${gles2-lib}
        dl
    )
endif()

# Aplica otimizações e LTO exclusivamente ao alvo libretro_jni (não propaga
# -ffast-math / -DNDEBUG / -flto para third_party/libadrenotools).
target_compile_options(libretro_jni PRIVATE
    -O3
    -ffast-math
    -fomit-frame-pointer
    -funroll-loops
    -flto
    -DNDEBUG
    -Wall
    -Wextra
)
target_link_options(libretro_jni PRIVATE -flto -O3)
