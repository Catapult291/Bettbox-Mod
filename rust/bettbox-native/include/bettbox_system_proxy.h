/*
 * Dart ↔ Rust 的窄 C ABI 声明（Windows 系统代理）。
 *
 * 这个头文件是 Dart 侧 ffigen 绑定的唯一输入（见仓库根
 * `ffigen.bettbox_system_proxy.yaml`），与 `src/system_ffi.rs` 的实现必须保持一致。
 *
 * 约定：
 *   - 字符串一律为 UTF-8 C 字符串，Rust 侧分配。
 *   - 调用方用完必须用 `bb_string_free` 释放；传 NULL 是合法的空操作。
 *   - 三个入口返回的**总是**一个 JSON 信封，不是 NULL：
 *       {"ok":true,...}                 成功
 *       {"ok":false,"message":"..."}    失败（含非 Windows 平台、Win32 调用失败、
 *                                       快照非法）；message 是给人看的失败原因。
 *     只有 ABI 级失败（指针为空、内存分配失败）才返回 NULL。
 */

#ifndef BETTBOX_SYSTEM_PROXY_H_
#define BETTBOX_SYSTEM_PROXY_H_

#ifdef __cplusplus
extern "C" {
#endif

/* 读取当前系统代理设置（LAN 连接 + 所有 RAS 拨号项）。
 * 信封：{"ok":true,"snapshot":{"version":1,"connections":[
 *          {"name":"VPN"|省略(LAN),"flags":3,"server":"...","bypass":"...",
 *           "autoconfig_url":"..."}]}}
 * 其中字符串项省略表示「本来没有这项设置」。 */
char *bb_system_proxy_query(void);

/* 启用指向 127.0.0.1:<port> 的系统代理。
 *   bypass  分号分隔的绕过域名（NULL / 空串表示只有默认的 <local>）。
 * 信封：{"ok":true,"snapshot":{...},"warnings":["<连接名>: <原因>",...]}
 * 其中 snapshot 是**启用前**的设置（带 applied 字段，见下），交给调用方持久化；
 * warnings 是 LAN 之外那些没能设置成功的连接（LAN 失败则整个调用失败）。
 *
 * snapshot.applied 记的是本应用写下的服务器串（"127.0.0.1:<port>"），
 * 还原时靠它判断某个连接是否仍归本应用管。 */
char *bb_system_proxy_enable(int port, const char *bypass);

/* 按快照还原系统代理：只还原仍归本应用管的连接（服务器串等于快照里的 applied），
 * 用户或别的程序在这期间改过的连接不动。
 * 信封：{"ok":true,"restored":1,"skipped":0,"warnings":[...]} */
char *bb_system_proxy_restore(const char *snapshot_json);

/* 释放本库返回的字符串。 */
void bb_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* BETTBOX_SYSTEM_PROXY_H_ */
