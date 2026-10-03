/*
 * Dart ↔ Rust 的窄 C ABI 声明（覆写脚本引擎）。
 *
 * 这个头文件是 Dart 侧 ffigen 绑定的唯一输入（见仓库根 `ffigen.bettbox_script.yaml`），
 * 与 `src/ffi.rs` 的实现必须保持一致。
 *
 * 约定（与 `bettbox_config.h` 相同）：
 *   - 字符串一律为 UTF-8 C 字符串，Rust 侧分配。
 *   - 调用方用完必须用 `bb_string_free` 释放；传 NULL 是合法的空操作。
 *   - NULL 返回值的含义是「本库不接管，回退 Dart 侧 qjs 路径」，
 *     入参非法（NULL / 非 UTF-8 / 配置不是 JSON 对象）时出现；
 *     脚本自身的错误走信封，不是 NULL。
 *   - 三个入参都必须**以 NUL 结尾**（Dart 的 `toNativeUtf8()` 天然满足）。
 *     内嵌的 QuickJS 在部分词法路径上会读取结束位置之后的一个字节，只给长度
 *     不给 NUL 时解析结果会取决于紧邻内存，实测为随机语法错误。
 */

#ifndef BETTBOX_SCRIPT_H_
#define BETTBOX_SCRIPT_H_

#ifdef __cplusplus
extern "C" {
#endif

/* 执行覆写脚本并返回 JSON 信封。
 *
 *   config_json   当前配置（JSON 对象文本），脚本的 `main(config)` 收到它。
 *   options_json  可选的自定义选项（JSON 对象文本，NULL 表示没有）；
 *                 非 NULL 时按 Dart 侧规则合并进全局 `ruleOptionsEnable`。
 *
 * 信封形状：
 *   {"ok":true,"config":{...}}   脚本正常执行且返回对象
 *   {"ok":true,"config":<原样>}  脚本返回值不是对象（与 Dart 侧 `result is Map` 一致）
 *   {"ok":false,"error":"..."}   脚本抛错 / 超时 / 内存超限，
 *                                错误串格式与 Dart 侧一致（`JS Script Error: ...`）
 *
 * 上界与 Dart 侧 `lib/common/js_runtime_manager.dart` 一致：30 s 超时、256 MB 内存、
 * 失败重试一次。求值是同步的，调用方必须放在后台 isolate/线程里。 */
char *bb_eval_script(const char *script,
                     const char *config_json,
                     const char *options_json);

/* 释放本库返回的字符串。 */
void bb_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* BETTBOX_SCRIPT_H_ */
