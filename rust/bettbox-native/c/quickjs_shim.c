/*
 * QuickJS 求值的薄封装。
 *
 * 存在的理由：Rust 侧不该碰 JSValue。QuickJS 把 JSValue 的判型/取值都写成
 * quickjs.h 里的 static inline（JS_IsException / JS_VALUE_GET_TAG / JS_FreeValue…），
 * Rust 调不到；而按值传 16 字节的 JSValue 跨 FFI 又依赖编译器 ABI 细节。
 * 所以整个引擎交互留在 C 侧，Rust 只看到「C 字符串进、C 字符串出」。
 *
 * 入参契约：`program` 必须**以 NUL 结尾**。QuickJS 的词法分析在若干路径上会读取
 * 结束位置之后的那一个字节（Dart 侧传的是 `toNativeUtf8()`，天然带 NUL，所以从未
 * 暴露）；只给长度不给 NUL 时，解析结果会取决于紧邻堆内存的内容——实测表现为随机
 * 的 `SyntaxError: unexpected character`、`'\u{1}'` 之类，甚至把越界字节当成 JS 执行
 * 出 `ReferenceError: 'xxx' is not defined`。
 *
 * 用法与 Dart 侧 `plugins/flutter_qjs/cxx/ffi.cpp` 同源裁剪：同一次求值一个新
 * runtime、同样的 clock() 计时中断（超时）、同样的 JS_Eval 全局代码求值。
 * 编译开关也对齐插件的 Windows 构建（见 build.rs 的 opt_level/NDEBUG 说明）。
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs.h"
#include "libregexp.h"

#ifdef _MSC_VER
#define BBQ_EXPORT __declspec(dllexport)
#else
#define BBQ_EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
  int64_t timeout_ms;
  clock_t start;
} bbq_state;

static int bbq_interrupt_handler(JSRuntime *rt, void *opaque) {
  bbq_state *state = (bbq_state *)opaque;
  if (state->timeout_ms > 0 && state->start != 0 &&
      (clock() - state->start) >
          (clock_t)(state->timeout_ms * CLOCKS_PER_SEC / 1000)) {
    state->start = 0;
    return 1;
  }
  return 0;
}

static char *bbq_strdup(const char *src, size_t len) {
  char *out = (char *)malloc(len + 1);
  if (out == NULL) {
    return NULL;
  }
  if (len > 0) {
    memcpy(out, src, len);
  }
  out[len] = '\0';
  return out;
}

/* 取走当前异常并格式化成一张 C 字符串（始终消费掉 pending exception）。
 *
 * 形状照抄 Dart 侧 `JSError.toString()`（`plugins/flutter_qjs/lib/src/object.dart`）：
 * 异常对象带非空 `stack` 属性时拼成 `message\nstack`，否则只给 message。Dart 侧的
 * `stack` 来自 `wrapper.dart` 里对异常的 `stack` 属性读取，少了它报错提示会比 qjs
 * 路径短一截（脚本正文由用户编写，栈是唯一能定位到出错的脚本行的线索）。 */
static char *bbq_take_exception(JSContext *ctx) {
  JSValue exc = JS_GetException(ctx);
  const char *message = JS_ToCString(ctx, exc);
  const char *stack = NULL;
  JSValue stack_value = JS_GetPropertyStr(ctx, exc, "stack");
  if (JS_IsException(stack_value)) {
    JS_FreeValue(ctx, JS_GetException(ctx));
  } else if (JS_ToBool(ctx, stack_value) > 0) {
    stack = JS_ToCString(ctx, stack_value);
  }

  char *out = NULL;
  if (message != NULL) {
    size_t message_len = strlen(message);
    if (stack != NULL && stack[0] != '\0') {
      size_t stack_len = strlen(stack);
      out = (char *)malloc(message_len + 1 + stack_len + 1);
      if (out != NULL) {
        memcpy(out, message, message_len);
        out[message_len] = '\n';
        memcpy(out + message_len + 1, stack, stack_len);
        out[message_len + 1 + stack_len] = '\0';
      }
    } else {
      out = bbq_strdup(message, message_len);
    }
  }

  if (stack != NULL) {
    JS_FreeCString(ctx, stack);
  }
  if (message != NULL) {
    JS_FreeCString(ctx, message);
  }
  JS_FreeValue(ctx, stack_value);
  JS_FreeValue(ctx, exc);
  return out;
}

/* 求值 program（脚本正文 + main 调用已在 Rust 侧拼好）。
 *
 * 返回：
 *   0  *out_json  = 结果对象的 JSON 文本
 *   2  结果不是对象（或数组）→ 调用方保留原配置，与 Dart 侧 `result is Map` 一致
 *   1  *out_error = 脚本异常（含超时被中断、内存超限）
 *  -1  内部错误（runtime/context 创建失败、编码失败、内存分配失败）
 */
BBQ_EXPORT int32_t bbq_eval_program(const char *program, size_t program_len,
                                    int64_t timeout_ms, size_t memory_limit,
                                    char **out_json, char **out_error) {
  if (out_json != NULL) {
    *out_json = NULL;
  }
  if (out_error != NULL) {
    *out_error = NULL;
  }

  JSRuntime *rt = JS_NewRuntime();
  if (rt == NULL) {
    return -1;
  }
  bbq_state state = {timeout_ms, 0};
  JS_SetInterruptHandler(rt, bbq_interrupt_handler, &state);
  if (memory_limit > 0) {
    JS_SetMemoryLimit(rt, memory_limit);
  }

  JSContext *ctx = JS_NewContext(rt);
  if (ctx == NULL) {
    JS_FreeRuntime(rt);
    return -1;
  }

  JS_UpdateStackTop(rt);
  state.start = clock();
  /* 文件名与 Dart 侧一致：`JS_Eval` 的 filename 为 NULL/空时 QuickJS 用 "<eval>"，
   * 而 Dart 侧 `Engine.evaluate` 显式传 "<eval>"（见 ffi.dart 的 jsEval 默认名）。
   * 名字不同会让异常栈里的 `(<eval>:N)` 变成别的文件名，报错串就对不上了。 */
  JSValue result = JS_Eval(ctx, program, program_len, "<eval>",
                           JS_EVAL_TYPE_GLOBAL);

  int32_t status;
  if (JS_IsException(result)) {
    if (out_error != NULL) {
      *out_error = bbq_take_exception(ctx);
      if (*out_error == NULL) {
        *out_error = bbq_strdup("unknown script error", 21);
      }
    } else {
      free(bbq_take_exception(ctx));
    }
    status = 1;
  } else if (!JS_IsObject(result) || JS_IsArray(ctx, result)) {
    status = 2;
  } else {
    JSValue json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json) || JS_IsUndefined(json)) {
      /* JSON.stringify 对函数/undefined 返回 undefined，按「不是 Map」处理。 */
      if (JS_IsException(json)) {
        if (out_error != NULL) {
          *out_error = bbq_take_exception(ctx);
          if (*out_error == NULL) {
            *out_error = bbq_strdup("json stringify failed", 22);
          }
        } else {
          free(bbq_take_exception(ctx));
        }
        status = 1;
      } else {
        status = 2;
      }
    } else {
      const char *text = JS_ToCString(ctx, json);
      if (text == NULL) {
        status = -1;
      } else {
        if (out_json != NULL) {
          *out_json = bbq_strdup(text, strlen(text));
          status = *out_json != NULL ? 0 : -1;
        } else {
          status = -1;
        }
        JS_FreeCString(ctx, text);
      }
      JS_FreeValue(ctx, json);
    }
  }

  if (!JS_IsException(result)) {
    JS_FreeValue(ctx, result);
  }
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return status;
}

BBQ_EXPORT void bbq_string_free(char *ptr) { free(ptr); }

/*
 * 节点过滤用的正则匹配（QuickJS 自带的 libregexp）。
 *
 * 为什么句柄里要带一个 runtime/context：libregexp 把内存分配与栈检查留给嵌入方，
 * 本仓库的 `lre_realloc` / `lre_check_stack_overflow`（quickjs.c）都把 `opaque`
 * 当 JSContext 用（`js_realloc_rt(ctx->rt, …)`），所以 opaque 必须是一个真实的
 * context，不能塞别的指针。每个句柄自持一套，互不共享，因此跨线程安全。
 *
 * 句柄在 Rust 侧由 `RegexMatcher` 的 Drop 释放；每次编译返回新句柄。
 */
typedef struct {
  JSRuntime *rt;
  JSContext *ctx;
  uint8_t *bytecode;
} bbq_regex;

/* 编译模式。
 *
 * 入参契约：`pattern` 必须**以 NUL 结尾**（与 bbq_eval_program 的 program 同理——
 * lre_compile 解析完会读 `*buf_ptr` 判断是否有多余字符，不补 NUL 就会越界读）。
 * `pattern_len` 不含这个 NUL。模式按 CESU-8 传入、`re_flags = 0`（非 unicode），
 * 与 Dart 侧 `RegExp(pattern)` 的语义一致。
 *
 * 返回句柄；模式语法非法或内存不足返回 NULL。 */
BBQ_EXPORT void *bbq_regex_compile(const char *pattern, size_t pattern_len) {
  JSRuntime *rt = JS_NewRuntime();
  if (rt == NULL) {
    return NULL;
  }
  JSContext *ctx = JS_NewContext(rt);
  if (ctx == NULL) {
    JS_FreeRuntime(rt);
    return NULL;
  }
  JS_UpdateStackTop(rt);

  char error_msg[128];
  int len = 0;
  uint8_t *bytecode = lre_compile(&len, error_msg, sizeof(error_msg), pattern,
                                  pattern_len, 0, ctx);
  if (bytecode == NULL) {
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return NULL;
  }

  bbq_regex *handle = (bbq_regex *)malloc(sizeof(bbq_regex));
  if (handle == NULL) {
    lre_realloc(ctx, bytecode, 0);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return NULL;
  }
  handle->rt = rt;
  handle->ctx = ctx;
  handle->bytecode = bytecode;
  return handle;
}

/* `text` 为 UTF-16 码元数组（与 Dart 非 unicode RegExp 一致：按码元匹配）。
 * 返回 1 命中、0 未命中、-1 内部错误（句柄为空或内存不足）。 */
BBQ_EXPORT int32_t bbq_regex_is_match(void *handle_ptr, const uint16_t *text,
                                      size_t text_len) {
  bbq_regex *handle = (bbq_regex *)handle_ptr;
  if (handle == NULL) {
    return -1;
  }
  int capture_count = lre_get_capture_count(handle->bytecode);
  uint8_t **capture = NULL;
  if (capture_count > 0) {
    /* 反向引用等需要捕获组；这里只判定是否命中，缓冲区仅作临时存放。 */
    capture = (uint8_t **)calloc((size_t)capture_count * 2, sizeof(uint8_t *));
    if (capture == NULL) {
      return -1;
    }
  }
  int ret = lre_exec(capture, handle->bytecode, (const uint8_t *)text, 0,
                     (int)text_len, 1, handle->ctx);
  free(capture);
  if (ret < 0) {
    return -1;
  }
  return ret == 1 ? 1 : 0;
}

BBQ_EXPORT void bbq_regex_free(void *handle_ptr) {
  bbq_regex *handle = (bbq_regex *)handle_ptr;
  if (handle == NULL) {
    return;
  }
  if (handle->bytecode != NULL) {
    /* 字节码由 libregexp 经 lre_realloc 分配，必须用同一个分配器释放。 */
    lre_realloc(handle->ctx, handle->bytecode, 0);
  }
  JS_FreeContext(handle->ctx);
  JS_FreeRuntime(handle->rt);
  free(handle);
}
