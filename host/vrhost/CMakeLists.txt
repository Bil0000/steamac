# SPDX-License-Identifier: GPL-3.0-or-later
# steamac-vrhost: Mac-native VR host (WiVRn-compatible server). A separate executable from steamac-vm because it
# contains GPL-3.0-or-later WiVRn code; see COPYING and docs/vr.md.
cmake_minimum_required(VERSION 3.25)
project(steamac-vrhost LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 23)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT APPLE)
	message(FATAL_ERROR "steamac-vrhost is macOS only")
endif()

include(FetchContent)
# Header-only dependencies, same versions as WiVRn v26.9 (CMakeLists.txt there). The protocol hash depends on the
# OpenXR header's array sizes, so the OpenXR-SDK version must match the pinned WiVRn tag.
FetchContent_Declare(openxr_sdk URL https://github.com/KhronosGroup/OpenXR-SDK/archive/refs/tags/release-1.1.58.tar.gz
	SOURCE_SUBDIR do-not-add)
FetchContent_Declare(boost_pfr URL https://github.com/boostorg/pfr/archive/refs/tags/boost-1.89.0.tar.gz
	SOURCE_SUBDIR do-not-add)
FetchContent_MakeAvailable(openxr_sdk boost_pfr)

find_package(OpenSSL 3 REQUIRED COMPONENTS Crypto)

# --- WiVRn common (vendored unmodified from WiVRn v26.9, see third_party/wivrn/UPSTREAM.md) ---
add_library(wivrn-common STATIC
	third_party/wivrn/common/crypto.cpp
	third_party/wivrn/common/secrets.cpp
	third_party/wivrn/common/smp.cpp
	third_party/wivrn/common/wivrn_sockets.cpp)
target_include_directories(wivrn-common SYSTEM PUBLIC
	third_party/wivrn/common
	third_party/wivrn/external
	${openxr_sdk_SOURCE_DIR}/include
	${boost_pfr_SOURCE_DIR}/include)
target_compile_options(wivrn-common PUBLIC
	"SHELL:-include ${CMAKE_CURRENT_SOURCE_DIR}/compat/wivrn_macos_compat.h")
target_compile_options(wivrn-common PRIVATE -Wno-c++11-narrowing)
target_link_libraries(wivrn-common PUBLIC OpenSSL::Crypto)

# --- host core (session interface, WiVRn adapter, encoder, test pattern) ---
add_library(vrhost-core STATIC
	src/session/clock.cpp
	src/session/pose_history.cpp
	src/wivrn/wivrn_session.cpp
	src/wivrn/dnssd_publisher.cpp
	src/wivrn/annexb.cpp
	src/encoder/vt_encoder.mm
	src/pattern/test_pattern.mm)
target_include_directories(vrhost-core PUBLIC src include)
target_link_libraries(vrhost-core PUBLIC wivrn-common
	"-framework CoreFoundation" "-framework CoreMedia" "-framework CoreVideo" "-framework VideoToolbox"
	"-framework IOSurface" "-framework Metal" "-framework Foundation")
target_compile_options(vrhost-core PRIVATE -Wall -Wextra -Wno-unused-parameter)
set_source_files_properties(src/encoder/vt_encoder.mm src/pattern/test_pattern.mm PROPERTIES COMPILE_FLAGS -fobjc-arc)

# --- game frames (M1 compositor + VR link) and the pipeline into the session ---
include(compositor.cmake)
target_sources(vrhost-compositor PRIVATE src/pipeline/vr_pipeline.mm)
set_source_files_properties(src/pipeline/vr_pipeline.mm PROPERTIES COMPILE_FLAGS -fobjc-arc)
target_link_libraries(vrhost-compositor PUBLIC vrhost-core)

add_executable(steamac-vrhost src/main.cpp)
target_link_libraries(steamac-vrhost PRIVATE vrhost-core vrhost-compositor)

# --- tests (ctest) ---
option(VRHOST_TESTS "Build the tests" ON)
if(VRHOST_TESTS)
enable_testing()
foreach(t protocol annexb pose_history encoder loopback)
	add_executable(test_${t} tests/test_${t}.cpp)
	target_link_libraries(test_${t} PRIVATE vrhost-core)
	add_test(NAME ${t} COMMAND test_${t})
endforeach()
target_sources(test_loopback PRIVATE tests/fake_headset.cpp)
target_sources(test_encoder PRIVATE tests/vt_decode.mm)
target_sources(test_loopback PRIVATE tests/vt_decode.mm)
set_source_files_properties(tests/vt_decode.mm PROPERTIES COMPILE_FLAGS -fobjc-arc)
set_tests_properties(encoder loopback PROPERTIES TIMEOUT 60)

# End-to-end game-frame test (wmtr exporter -> link -> compositor -> session -> test headset). The exporter
# (wmtr/src/wmtr_vr.m) needs the WMTVRSubmitInfo layout from a StonkGuy/dxmt vr-export checkout.
set(VRHOST_DXMT_DIR "" CACHE PATH "StonkGuy/dxmt vr-export checkout (enables the vr_e2e test)")
if(VRHOST_DXMT_DIR)
	enable_language(OBJC)
	set(wmtr_dir ${CMAKE_CURRENT_SOURCE_DIR}/../../wmtr)
	add_library(vrhost-test-exporter STATIC ${wmtr_dir}/src/wmtr_vr.m)
	target_include_directories(vrhost-test-exporter PRIVATE include ${wmtr_dir}/include ${VRHOST_DXMT_DIR}/src/winemetal)
	target_compile_options(vrhost-test-exporter PRIVATE -w)
	add_executable(test_vr_e2e tests/test_vr_e2e.mm tests/fake_headset.cpp tests/vt_decode.mm)
	target_include_directories(test_vr_e2e PRIVATE ${wmtr_dir}/include ${VRHOST_DXMT_DIR}/src/winemetal)
	set_source_files_properties(tests/test_vr_e2e.mm PROPERTIES COMPILE_FLAGS -fobjc-arc)
	target_link_libraries(test_vr_e2e PRIVATE vrhost-core vrhost-compositor vrhost-test-exporter "-framework Metal")
	add_test(NAME vr_e2e COMMAND test_vr_e2e)
	set_tests_properties(vr_e2e PROPERTIES TIMEOUT 90)
else()
	message(STATUS "vr_e2e test off: set VRHOST_DXMT_DIR to a StonkGuy/dxmt vr-export checkout")
endif()
endif()
