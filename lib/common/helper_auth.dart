import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'common.dart';

const _cryptProtectUiForbidden = 0x1;

class HelperAuthManager {
  static String? _authKey;

  static String? getAuthKey() => _authKey;

  static Future<bool> ensureAuthKey() async {
    if (_authKey != null) {
      return false;
    }

    final file = File(await appPath.helperAuthKeyPath);
    final existingKey = await _readPersistedAuthKey(file);
    if (existingKey != null) {
      _authKey = existingKey;
      commonPrint.log('[HelperAuth] Loaded auth key from file.');
      return false;
    }

    _authKey = _generateRandomKey();
    await _persistAuthKey(file, _authKey!);
    commonPrint.log('[HelperAuth] Generated new random auth key.');
    return true;
  }

  /// 把当前 key 明文写进数据目录，供 helper（SYSTEM）启动时读取。
  ///
  /// 该文件继承数据目录的 ACL（当前用户 + SYSTEM + Administrators），因此服务
  /// 注册表里只保存路径、不再保存明文 key。
  static Future<String?> writeServiceKeyFile() async {
    final key = _authKey;
    if (key == null) return null;

    try {
      final file = File(await appPath.helperServiceKeyPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(key, flush: true);
      return file.path;
    } catch (e) {
      commonPrint.log('[HelperAuth] Failed to write service auth key file: $e');
      return null;
    }
  }

  /// 取当前进程用户的 SID，用于把 helper 命名管道的 ACL 收紧到本用户。
  ///
  /// 不用 PATH 里的 `whoami`：MSYS/Git-Bash 的 coreutils `whoami` 会遮蔽 Windows
  /// 的同名程序且不认 `/user`。
  static Future<String?> currentUserSid() async {
    if (!Platform.isWindows) return null;

    try {
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final result = await Process.run(
        '$systemRoot\\System32\\whoami.exe',
        const ['/user'],
        stdoutEncoding: latin1,
      );
      if (result.exitCode != 0) return null;
      return RegExp(
        r'S-\d+(?:-\d+)+',
      ).firstMatch(result.stdout.toString())?.group(0);
    } catch (e) {
      commonPrint.log('[HelperAuth] Failed to resolve current user SID: $e');
      return null;
    }
  }

  static Map<String, String> generateAuthHeaders(String body) {
    if (_authKey == null) {
      return {};
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = '$timestamp:$body';

    final keyBytes = _hexToBytes(_authKey!);
    final messageBytes = utf8.encode(message);
    final hmacSha256 = Hmac(sha256, keyBytes);
    final digest = hmacSha256.convert(messageBytes);
    final signature = digest.toString();

    return {'X-Timestamp': timestamp.toString(), 'X-Signature': signature};
  }

  static Future<void> clearAuthKey() async {
    _authKey = null;
    final file = File(await appPath.helperAuthKeyPath);
    if (await file.exists()) {
      await file.delete();
    }
    final serviceKeyFile = File(await appPath.helperServiceKeyPath);
    if (await serviceKeyFile.exists()) {
      await serviceKeyFile.delete();
    }
  }

  static String _generateRandomKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> _readPersistedAuthKey(File file) async {
    if (!await file.exists()) {
      return null;
    }

    try {
      final encoded = await file.readAsString();
      if (encoded.isEmpty) {
        return null;
      }
      final encrypted = base64Decode(encoded);
      final decrypted = Platform.isWindows
          ? _unprotectForCurrentUser(Uint8List.fromList(encrypted))
          : Uint8List.fromList(encrypted);
      final key = utf8.decode(decrypted);
      if (!_isValidHexKey(key)) {
        return null;
      }
      return key;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persistAuthKey(File file, String key) async {
    final raw = Uint8List.fromList(utf8.encode(key));
    final encrypted = Platform.isWindows ? _protectForCurrentUser(raw) : raw;
    await file.parent.create(recursive: true);
    await file.writeAsString(base64Encode(encrypted), flush: true);
  }

  static bool _isValidHexKey(String value) {
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  }

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  static Uint8List _protectForCurrentUser(Uint8List input) {
    final dataIn = calloc<CRYPT_INTEGER_BLOB>();
    final dataOut = calloc<CRYPT_INTEGER_BLOB>();
    final inputBuffer = calloc<Uint8>(input.length);

    try {
      inputBuffer.asTypedList(input.length).setAll(0, input);
      dataIn.ref.cbData = input.length;
      dataIn.ref.pbData = inputBuffer;

      final result = CryptProtectData(
        dataIn,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        dataOut,
      );
      if (result == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }

      return Uint8List.fromList(
        dataOut.ref.pbData.asTypedList(dataOut.ref.cbData),
      );
    } finally {
      if (dataOut.ref.pbData != nullptr) {
        LocalFree(dataOut.ref.pbData);
      }
      calloc.free(inputBuffer);
      calloc.free(dataIn);
      calloc.free(dataOut);
    }
  }

  static Uint8List _unprotectForCurrentUser(Uint8List input) {
    final dataIn = calloc<CRYPT_INTEGER_BLOB>();
    final dataOut = calloc<CRYPT_INTEGER_BLOB>();
    final inputBuffer = calloc<Uint8>(input.length);

    try {
      inputBuffer.asTypedList(input.length).setAll(0, input);
      dataIn.ref.cbData = input.length;
      dataIn.ref.pbData = inputBuffer;

      final result = CryptUnprotectData(
        dataIn,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        _cryptProtectUiForbidden,
        dataOut,
      );
      if (result == 0) {
        throw WindowsException(HRESULT_FROM_WIN32(GetLastError()));
      }

      return Uint8List.fromList(
        dataOut.ref.pbData.asTypedList(dataOut.ref.cbData),
      );
    } finally {
      if (dataOut.ref.pbData != nullptr) {
        LocalFree(dataOut.ref.pbData);
      }
      calloc.free(inputBuffer);
      calloc.free(dataIn);
      calloc.free(dataOut);
    }
  }
}
