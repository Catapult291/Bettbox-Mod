cmake_minimum_required(VERSION 3.10 FATAL_ERROR)
set(CXX_LIB_DIR ${CMAKE_CURRENT_LIST_DIR})

# quickjs
# 源码已移入 Rust crate，仓库里只有这一份；插件双轨期仍要用它做参照，所以从这里指过去。
# 见 rust/bettbox-native/vendor/README.txt。
#
# 不能按固定层数上溯（如 `${CMAKE_CURRENT_LIST_DIR}/../../../rust/...`）：桌面端 Flutter 把插件
# 放在 `<平台>/flutter/ephemeral/.plugin_symlinks/<name>` 下引用，那里可能是符号链接，也可能是
# 插件目录的副本（Windows 无符号链接权限时 Flutter 会退化成复制）——两种情况下「相对插件目录往上
# 固定层数」都不落在仓库根，配置期直接失败。改为从本文件所在目录逐级向上找含该源码的仓库根。
# 也接受外部显式指定（BETTBOX_QUICKJS_DIR），便于把插件移出仓库单独使用。
if(NOT DEFINED BETTBOX_QUICKJS_DIR OR BETTBOX_QUICKJS_DIR STREQUAL "")
    set(_probe "${CXX_LIB_DIR}")
    while(NOT BETTBOX_QUICKJS_DIR)
        if(EXISTS "${_probe}/rust/bettbox-native/vendor/quickjs/quickjs.c")
            set(BETTBOX_QUICKJS_DIR "${_probe}/rust/bettbox-native/vendor/quickjs")
            break()
        endif()
        get_filename_component(_probe_parent "${_probe}" DIRECTORY)
        if(_probe_parent STREQUAL _probe)
            break()
        endif()
        set(_probe "${_probe_parent}")
    endwhile()
endif()
if(NOT EXISTS "${BETTBOX_QUICKJS_DIR}/quickjs.c")
    message(FATAL_ERROR
        "找不到 vendored QuickJS（BETTBOX_QUICKJS_DIR='${BETTBOX_QUICKJS_DIR}'）：它应在 "
        "rust/bettbox-native/vendor/quickjs，见 rust/bettbox-native/vendor/README.txt")
endif()
get_filename_component(QUICK_JS_LIB_DIR "${BETTBOX_QUICKJS_DIR}" ABSOLUTE)
file (STRINGS "${QUICK_JS_LIB_DIR}/VERSION" QUICKJS_VERSION)
add_library(quickjs STATIC
    ${QUICK_JS_LIB_DIR}/cutils.c
    ${QUICK_JS_LIB_DIR}/libregexp.c
    ${QUICK_JS_LIB_DIR}/libunicode.c
    ${QUICK_JS_LIB_DIR}/quickjs.c
)

# `cxx/ffi.h` 里写的是 `#include "quickjs/quickjs.h"`。源码原先与 ffi.h 同级（`cxx/quickjs/`），
# 这条靠「包含文件所在目录」的查找就能命中；移进 crate 后不再成立，改为显式给出父目录。
target_include_directories(quickjs PUBLIC
    "${QUICK_JS_LIB_DIR}"
    "${QUICK_JS_LIB_DIR}/.."
)

project(quickjs LANGUAGES C)
target_compile_options(quickjs PRIVATE "-DCONFIG_VERSION=\"${QUICKJS_VERSION}\"")
target_compile_options(quickjs PRIVATE "-DDUMP_LEAKS")

if(MSVC)
    # https://github.com/ekibun/flutter_qjs/issues/7
    target_compile_options(quickjs PRIVATE "/Oi-")
    target_compile_definitions(quickjs PRIVATE "alloca=_alloca")
endif()