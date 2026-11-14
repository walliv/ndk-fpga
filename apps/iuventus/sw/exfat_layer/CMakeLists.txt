# CMakeLists.txt: host exFAT metadata library, CLI and tests of the Iuventus file layer
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20)
project(iuv_exfat VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

set(IUV_EXFAT_WITH_NFB "AUTO" CACHE STRING "Build the libnfb MI bus: AUTO, ON or OFF")
set_property(CACHE IUV_EXFAT_WITH_NFB PROPERTY STRINGS AUTO ON OFF)
set(NFB_ROOT "" CACHE PATH "Optional libnfb install or build prefix")

set(IUV_WARNINGS -Wall -Wextra -Werror)

add_library(iuv_exfat STATIC
    src/block_device.cpp
    src/exfat_format.cpp
    src/file_io.cpp
    src/file_shell_model.cpp
    src/job.cpp
    src/nfb_mi_bus.cpp
    src/util.cpp
    src/volume.cpp
)
target_include_directories(iuv_exfat PUBLIC include PRIVATE src)
target_compile_options(iuv_exfat PRIVATE ${IUV_WARNINGS})

if(NOT IUV_EXFAT_WITH_NFB STREQUAL "OFF")
    find_path(NFB_INCLUDE_DIR nfb/nfb.h HINTS ${NFB_ROOT} PATH_SUFFIXES include)
    find_library(NFB_LIBRARY nfb HINTS ${NFB_ROOT} PATH_SUFFIXES lib lib64 build)
    find_library(FDT_LIBRARY fdt)
    if(NFB_INCLUDE_DIR AND NFB_LIBRARY)
        message(STATUS "libnfb found: ${NFB_LIBRARY}")
        target_compile_definitions(iuv_exfat PUBLIC IUV_EXFAT_HAVE_NFB=1)
        target_include_directories(iuv_exfat PRIVATE ${NFB_INCLUDE_DIR})
        target_link_libraries(iuv_exfat PUBLIC ${NFB_LIBRARY})
        if(FDT_LIBRARY)
            target_link_libraries(iuv_exfat PUBLIC ${FDT_LIBRARY})
        endif()
    elseif(IUV_EXFAT_WITH_NFB STREQUAL "ON")
        message(FATAL_ERROR "IUV_EXFAT_WITH_NFB=ON but libnfb was not found (set NFB_ROOT)")
    else()
        message(STATUS "libnfb not found: building without the card MI bus")
    endif()
endif()

add_executable(iuv-exfat tools/iuv_exfat.cpp)
target_link_libraries(iuv-exfat PRIVATE iuv_exfat)
target_compile_options(iuv-exfat PRIVATE ${IUV_WARNINGS})

include(CTest)
if(BUILD_TESTING)
    find_program(MKFS_EXFAT mkfs.exfat)
    find_program(FSCK_EXFAT fsck.exfat)
    find_package(Python3 COMPONENTS Interpreter)
    set(IUV_TEST_TMP ${CMAKE_BINARY_DIR}/test_tmp)

    add_library(iuv_test_util STATIC tests/test_util.cpp)
    target_link_libraries(iuv_test_util PUBLIC iuv_exfat)
    target_include_directories(iuv_test_util PUBLIC tests)
    target_compile_options(iuv_test_util PRIVATE ${IUV_WARNINGS})
    target_compile_definitions(iuv_test_util PRIVATE
        IUV_TEST_TMP="${IUV_TEST_TMP}"
        IUV_MKFS="${MKFS_EXFAT}"
        IUV_FSCK="${FSCK_EXFAT}"
        IUV_PYTHON="${Python3_EXECUTABLE}"
        IUV_BITMAP_CHECK="${CMAKE_CURRENT_SOURCE_DIR}/tests/exfat_bitmap_check.py")

    set(IUV_TESTS test_open_put test_reserve test_job test_crash test_large_open test_loop_mount)
    foreach(t IN LISTS IUV_TESTS)
        add_executable(${t} tests/${t}.cpp)
        target_link_libraries(${t} PRIVATE iuv_test_util)
        target_compile_options(${t} PRIVATE ${IUV_WARNINGS})
        add_test(NAME ${t} COMMAND ${t})
        set_tests_properties(${t} PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 1200)
    endforeach()

    add_test(NAME cli_smoke COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/tests/cli_smoke.sh $<TARGET_FILE:iuv-exfat>
        ${IUV_TEST_TMP}/cli_smoke ${CMAKE_CURRENT_SOURCE_DIR}/tests/exfat_bitmap_check.py)
    set_tests_properties(cli_smoke PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 600)
endif()
