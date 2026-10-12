/*
 * Dart ↔ Rust 的窄 C ABI 声明。
 *
 * 这个头文件是 Dart 侧 ffigen 绑定的唯一输入（见仓库根 `ffigen.bettbox_config.yaml`），
 * 与 `src/ffi.rs` 的实现必须保持一致。
 *
 * 约定：
 *   - 字符串一律为 UTF-8 C 字符串，Rust 侧分配。
 *   - 调用方用完必须用 `bb_string_free` 释放；传 NULL 是合法的空操作。
 *   - 出错（空指针 / 非 UTF-8 / 内存分配失败）返回 NULL。
 */

#ifndef BETTBOX_CONFIG_H_
#define BETTBOX_CONFIG_H_

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 解析一条 Clash 规则，返回 JSON 对象：
 * {"action":"DOMAIN","content":"example.com","target":"DIRECT",
 *  "ruleProvider":null,"subRule":null,"noResolve":false,"src":false}
 * 失败返回 NULL。 */
char *bb_rule_parse(const char *rule);

/* 解析后再序列化回配置字符串（往返校验用）。失败返回 NULL。 */
char *bb_rule_round_trip(const char *rule);

/* 解析 provider 列表原文，返回元数据数组 JSON（已剥掉全节点列表）。
 * 测试专用 ABI：生产只走 bb_patch_config / bb_process_profile，本函数供差分测试。
 * 失败返回 NULL。 */
char *bb_parse_provider_meta(const char *raw_providers_json);

/* 由内核代理表 + provider 原文构建分组，返回分组数组 JSON。
 * 测试专用 ABI：同 bb_parse_provider_meta。
 * raw_providers 传 NULL 或空串表示没有 provider 数据。失败返回 NULL。 */
char *bb_build_proxies_groups(const char *proxies_json, const char *raw_providers);

/* 跑完整条配置改写管道：input_json 见 src/patch_config.rs 的输入结构说明，
 * 返回改写后的配置 JSON。失败返回 NULL。 */
char *bb_patch_config(const char *input_json);

/* 合并入口：先对 input_json 里的 rawConfig 跑覆写脚本，再跑整条配置改写管道，
 * 让整份配置只跨一次 FFI（对应 Dart 侧 patchRawConfig 的 handleEvaluate + patch 两步）。
 * 信封：{"ok":true,"config":{...}} 或脚本失败时 {"ok":true,"config":{...},"scriptError":"..."}
 * （脚本失败不阻断 patch，错误交回调用方提示）；失败返回 NULL。
 * options_json 传 NULL 表示没有自定义选项。 */
char *bb_process_profile(const char *input_json,
                         const char *script,
                         const char *options_json);

/* 节点过滤用的正则匹配：命中返回 1，未命中返回 0，模式无法编译返回 -1。
 * 测试专用 ABI：供 regex 差分测试与 Dart RegExp 对拍，生产在 patch 内部直接调匹配器。 */
int bb_node_filter_match(const char *pattern, const char *text);

/* 释放本库返回的字符串。 */
void bb_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* BETTBOX_CONFIG_H_ */
