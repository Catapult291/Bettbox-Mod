#!/bin/sh
# iOS / macOS 侧的构建前准备：把 ffi 与本插件用到的 QuickJS 源码摊平到当前平台的 cxx/ 下。
#
# QuickJS 源码在 Rust crate 内（唯一副本），见 rust/bettbox-native/vendor/README.txt。
# 不按固定层数上溯：桌面端 Flutter 会把插件放到 <平台>/flutter/ephemeral/.plugin_symlinks/<name>，
# 那里可能是符号链接，也可能是插件目录的副本——两种情况下「相对插件目录往上固定层数」都不落在
# 仓库根。改为从本脚本所在目录逐级向上找含该源码的仓库根。
set -e

CXX_SRC="$(cd "$(dirname "$0")" && pwd)"
_probe="$CXX_SRC"
QUICKJS_SRC=""
while [ -n "$_probe" ]; do
    if [ -f "$_probe/rust/bettbox-native/vendor/quickjs/quickjs.c" ]; then
        QUICKJS_SRC="$_probe/rust/bettbox-native/vendor/quickjs"
        break
    fi
    _parent="$(dirname "$_probe")"
    [ "$_parent" = "$_probe" ] && break
    _probe="$_parent"
done

if [ -z "$QUICKJS_SRC" ]; then
    echo "找不到 vendored QuickJS（从 $CXX_SRC 逐级上溯未命中 rust/bettbox-native/vendor/quickjs）" >&2
    exit 1
fi

if [ -d "./cxx/" ];then
    rm -r ./cxx
fi

mkdir ./cxx

sed 's/\#include \"quickjs\/quickjs.h\"/\#include \"quickjs.h\"/g' "$CXX_SRC/ffi.h" > ./cxx/ffi.h
cp "$CXX_SRC/ffi.cpp" ./cxx/ffi.cpp

cp "$QUICKJS_SRC"/*.h ./cxx/
cp "$QUICKJS_SRC/cutils.c" ./cxx/
cp "$QUICKJS_SRC/libregexp.c" ./cxx/
cp "$QUICKJS_SRC/libunicode.c" ./cxx/

quickjs_version=$(cat "$QUICKJS_SRC/VERSION")

sed '1i\
\#define CONFIG_VERSION \"'$quickjs_version'\"\
\#define DUMP_LEAKS  1\
' "$QUICKJS_SRC/quickjs.c" > ./cxx/quickjs.c
