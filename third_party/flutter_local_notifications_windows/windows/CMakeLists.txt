# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "flutter_local_notifications_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(flutter_local_notifications_windows_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  # This can be changed to accommodate different builds.
  $<TARGET_FILE:flutter_local_notifications_windows>
  PARENT_SCOPE
)
target_link_libraries(flutter_local_notifications_windows PRIVATE runtimeobject ole32)
# C++/WinRT throws. The app's other targets turn exceptions off.
target_compile_options(flutter_local_notifications_windows PRIVATE /EHsc)
target_compile_definitions(flutter_local_notifications_windows PRIVATE _HAS_EXCEPTIONS=1)
if(CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION)
  set(_cppwinrt "C:/Program Files (x86)/Windows Kits/10/Include/${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}/cppwinrt")
  if(EXISTS "${_cppwinrt}")
    target_include_directories(flutter_local_notifications_windows PRIVATE "${_cppwinrt}")
  endif()
endif()
# Flutter configures this app with the VS 2022 Build Tools compiler. That
# install has the same MSVC toolset as Community but no ATL headers, so
# atlbase.h is missing. Use ATL from the matching toolset when it lives in
# another Visual Studio install.
set(_atl_root "")
set(_linker "${CMAKE_LINKER}")
string(REPLACE "\\" "/" _linker "${_linker}")
set(_msvc_ver "")
if(_linker MATCHES ".*/MSVC/([0-9.]+)/bin/")
  set(_msvc_ver "${CMAKE_MATCH_1}")
endif()
set(_atl_bases
  "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"
  "C:/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"
  "C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC"
  "C:/Program Files/Microsoft Visual Studio/2022/Professional/VC/Tools/MSVC"
  "C:/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC"
)
if(NOT _msvc_ver STREQUAL "")
  foreach(_atl_base ${_atl_bases})
    if(EXISTS "${_atl_base}/${_msvc_ver}/atlmfc/include/atlbase.h")
      set(_atl_root "${_atl_base}/${_msvc_ver}/atlmfc")
      break()
    endif()
  endforeach()
endif()
if(_atl_root STREQUAL "")
  file(GLOB _atl_headers
    "C:/Program Files/Microsoft Visual Studio/2022/*/VC/Tools/MSVC/*/atlmfc/include/atlbase.h"
    "C:/Program Files (x86)/Microsoft Visual Studio/2022/*/VC/Tools/MSVC/*/atlmfc/include/atlbase.h"
  )
  if(_atl_headers)
    list(SORT _atl_headers)
    list(GET _atl_headers -1 _atl_header)
    get_filename_component(_atl_inc "${_atl_header}" DIRECTORY)
    get_filename_component(_atl_root "${_atl_inc}" DIRECTORY)
  endif()
endif()
if(NOT _atl_root STREQUAL "")
  target_include_directories(flutter_local_notifications_windows PRIVATE "${_atl_root}/include")
  if(EXISTS "${_atl_root}/lib/x64/atls.lib")
    target_link_directories(flutter_local_notifications_windows PRIVATE "${_atl_root}/lib/x64")
  endif()
endif()
