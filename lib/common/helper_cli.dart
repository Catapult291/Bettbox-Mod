import 'dart:convert';

/// `helper.exe` 子命令的结果文件内容（见 `services/helper/src/cli.rs`）。
///
/// `ShellExecuteW(runas)` 拿不到子进程的 stdout，所以 helper 把结果写成 JSON：
/// `{"ok":bool,"command":str,"code":str|null,"message":str|null,"osError":u32|null}`。
class HelperCliResult {
  const HelperCliResult({
    required this.ok,
    this.command,
    this.code,
    this.message,
    this.osError,
  });

  /// 还没走到 helper（提权被拒、helper 不存在、超时）时的失败结果。
  const HelperCliResult.localFailure(this.code, this.message)
    : ok = false,
      command = null,
      osError = null;

  final bool ok;
  final String? command;
  final String? code;
  final String? message;
  final int? osError;

  /// 解析结果文件。内容不合法时按失败处理而不是抛异常——调用方要的是「成没成」。
  static HelperCliResult parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const HelperCliResult.localFailure(
          'INVALID_RESULT',
          'helper result is not a JSON object',
        );
      }

      return HelperCliResult(
        ok: decoded['ok'] == true,
        command: decoded['command'] as String?,
        code: decoded['code'] as String?,
        message: decoded['message'] as String?,
        osError: decoded['osError'] as int?,
      );
    } catch (e) {
      return HelperCliResult.localFailure(
        'INVALID_RESULT',
        'failed to parse the helper result: $e',
      );
    }
  }

  /// 日志用的一行描述。
  String get summary {
    if (ok) return 'ok';
    return [code ?? 'UNKNOWN', if (message != null) message].join(': ');
  }
}

/// 按 `CommandLineToArgvW` 的规则给单个参数加引号。
///
/// 反斜杠只在引号前需要翻倍，`"` 写成 `\"`。路径正常不会带 `"`，但用户名与安装目录
/// 不由我们控制，所以按完整规则转义而不是简单包一层引号。
String quoteWindowsArgument(String value) {
  if (value.isEmpty) return '""';
  if (!value.contains(RegExp(r'[ \t\n\v"]'))) return value;

  final buffer = StringBuffer('"');
  var backslashes = 0;

  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 0x5C) {
      backslashes++;
      continue;
    }
    if (codeUnit == 0x22) {
      buffer.write('\\' * (backslashes * 2 + 1));
      buffer.write('"');
      backslashes = 0;
      continue;
    }
    if (backslashes > 0) {
      buffer.write('\\' * backslashes);
      backslashes = 0;
    }
    buffer.writeCharCode(codeUnit);
  }

  buffer.write('\\' * (backslashes * 2));
  buffer.write('"');

  return buffer.toString();
}

/// 把参数列表拼成一条 Windows 命令行。
String quoteWindowsArguments(List<String> arguments) {
  return arguments.map(quoteWindowsArgument).join(' ');
}
