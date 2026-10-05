# iOS / macOS 侧的构建前准备：把 ffi 与本插件用到的 QuickJS 源码摊平到当前平台的 cxx/ 下。
# QuickJS 源码在 Rust crate 内（唯一副本），见 rust/bettbox-native/vendor/README.txt。
CXX_SRC="$(dirname "$0")"
QUICKJS_SRC="$CXX_SRC/../../../rust/bettbox-native/vendor/quickjs"

if [ ! -f "$QUICKJS_SRC/quickjs.c" ]; then
    echo "找不到 vendored QuickJS：$QUICKJS_SRC" >&2
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
