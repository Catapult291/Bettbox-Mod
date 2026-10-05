cmake_minimum_required(VERSION 3.10 FATAL_ERROR)
set(CXX_LIB_DIR ${CMAKE_CURRENT_LIST_DIR})

# quickjs
# 源码已移入 Rust crate，仓库里只有这一份；插件双轨期仍要用它做参照，所以从这里指过去。
# 见 rust/bettbox-native/vendor/README.txt。
get_filename_component(QUICK_JS_LIB_DIR
    "${CXX_LIB_DIR}/../../../rust/bettbox-native/vendor/quickjs" ABSOLUTE)
if(NOT EXISTS "${QUICK_JS_LIB_DIR}/quickjs.c")
    message(FATAL_ERROR "找不到 vendored QuickJS：${QUICK_JS_LIB_DIR}")
endif()
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