import 'package:bett_box/common/system.dart';
import 'package:bett_box/helper/helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-12 从现网 `sc qc BettboxHelperService` 抓取的真实输出（GBK 解码后）。
/// 第 50 节未决① 的事故现场：binPath 指向安装目录，而不是构建目录。
const _realScQcOutput = '''
[SC] QueryServiceConfig SUCCESS

SERVICE_NAME: BettboxHelperService
        TYPE               : 10  WIN32_OWN_PROCESS
        START_TYPE         : 2   AUTO_START
        ERROR_CONTROL      : 1   NORMAL
        BINARY_PATH_NAME   : C:\\Users\\bypassnro\\Documents\\Bettbox\\BettboxHelperService.exe
        LOAD_ORDER_GROUP   :
        TAG                : 0
        DISPLAY_NAME       : BettboxHelperService
        DEPENDENCIES       :
        SERVICE_START_NAME : LocalSystem
''';

void main() {
  group('classifyHelperPing', () {
    test('应答且 TOKEN 一致 → healthy', () {
      expect(
        classifyHelperPing(expectedToken: 'abc', data: 'abc'),
        HelperPingStatus.healthy,
      );
    });

    test('应答但 TOKEN 不一致 → incompatible（重装升级的正向证据）', () {
      expect(
        classifyHelperPing(expectedToken: 'abc', data: 'def'),
        HelperPingStatus.incompatible,
      );
    });

    test('期望 TOKEN 为空 → unreachable（无法证伪，按没拿到应答处理）', () {
      expect(
        classifyHelperPing(expectedToken: '', data: ''),
        HelperPingStatus.unreachable,
      );
    });

    test('UNAUTHORIZED / AUTH_* → authFailed', () {
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const HelperRpcException('UNAUTHORIZED', 'bad signature'),
        ),
        HelperPingStatus.authFailed,
      );
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const HelperRpcException(
            'AUTH_NOT_READY',
            'Helper auth key is not ready',
          ),
        ),
        HelperPingStatus.authFailed,
      );
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const HelperRpcException('AUTH_CLOCK_SKEW', 'skew'),
        ),
        HelperPingStatus.authFailed,
      );
    });

    test('UNSUPPORTED_VERSION / 其他 RPC 错误 → incompatible（helper 有应答）', () {
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const HelperRpcException(
            'UNSUPPORTED_VERSION',
            'Unsupported helper protocol version',
          ),
        ),
        HelperPingStatus.incompatible,
      );
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const HelperRpcException('INVALID_REQUEST', 'bad frame'),
        ),
        HelperPingStatus.incompatible,
      );
    });

    test('传输/解析异常 → unreachable', () {
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: StateError('Helper pipe connection timed out: 2'),
        ),
        HelperPingStatus.unreachable,
      );
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: Exception('read timeout'),
        ),
        HelperPingStatus.unreachable,
      );
      expect(
        classifyHelperPing(
          expectedToken: 'abc',
          error: const FormatException('Invalid helper response'),
        ),
        HelperPingStatus.unreachable,
      );
    });
  });

  group('planRegisterService 决策表', () {
    RegisterServiceAction plan(
      HelperServiceState state,
      HelperPingStatus ping,
      bool differs,
    ) => planRegisterService(state, ping, differs);

    test('服务不存在 → 一律 install（新装，不涉及改写现网）', () {
      for (final ping in HelperPingStatus.values) {
        for (final differs in [true, false]) {
          expect(
            plan(HelperServiceState.missing, ping, differs),
            RegisterServiceAction.install,
            reason: 'state=missing ping=${ping.name} differs=$differs',
          );
        }
      }
    });

    test('RUNNING + healthy → useExisting（含 binPath 指向他处：沿用不迁移）', () {
      for (final differs in [true, false]) {
        expect(
          plan(HelperServiceState.running, HelperPingStatus.healthy, differs),
          RegisterServiceAction.useExisting,
        );
      }
    });

    test('RUNNING + incompatible → install（§113 新 app 对旧 helper 升级路径）', () {
      for (final differs in [true, false]) {
        expect(
          plan(
            HelperServiceState.running,
            HelperPingStatus.incompatible,
            differs,
          ),
          RegisterServiceAction.install,
        );
      }
    });

    test('RUNNING + authFailed/unreachable：跨目录不动现网，同目录自愈重装', () {
      for (final ping in [
        HelperPingStatus.authFailed,
        HelperPingStatus.unreachable,
      ]) {
        expect(
          plan(HelperServiceState.running, ping, true),
          RegisterServiceAction.leaveUntouched,
          reason: 'ping=${ping.name} 跨目录必须不动现网服务（第 50 节未决①）',
        );
        expect(
          plan(HelperServiceState.running, ping, false),
          RegisterServiceAction.install,
          reason: 'ping=${ping.name} 同目录重装是既有自愈路径',
        );
      }
    });

    test('inactive：跨目录不动现网，同目录 install（与改前行为一致）', () {
      for (final ping in HelperPingStatus.values) {
        expect(
          plan(HelperServiceState.inactive, ping, true),
          RegisterServiceAction.leaveUntouched,
        );
        expect(
          plan(HelperServiceState.inactive, ping, false),
          RegisterServiceAction.install,
        );
      }
    });

    test('事故复演：SHA 对齐但 ping 瞬时失败 + 服务指在安装目录 → 不动现网', () {
      // 现场：内核 SHA 已对齐官方 TOKEN（53b5e088），首启管道/鉴权瞬时失败，
      // 改前代码走 install 把现网 binPath 改到了构建目录。
      expect(
        plan(HelperServiceState.running, HelperPingStatus.unreachable, true),
        RegisterServiceAction.leaveUntouched,
      );
      // 鉴权瞬时失败的假设同理。
      expect(
        plan(HelperServiceState.running, HelperPingStatus.authFailed, true),
        RegisterServiceAction.leaveUntouched,
      );
    });
  });

  group('serviceStateFromScQuery', () {
    test('非零退出 → missing（服务不存在）', () {
      expect(serviceStateFromScQuery(1060, ''), HelperServiceState.missing);
    });

    test('输出含 RUNNING → running', () {
      expect(
        serviceStateFromScQuery(
          0,
          'SERVICE_NAME: BettboxHelperService\n        STATE : 4  RUNNING',
        ),
        HelperServiceState.running,
      );
    });

    test('STOPPED / START_PENDING 等 → inactive', () {
      expect(
        serviceStateFromScQuery(0, 'STATE : 1  STOPPED'),
        HelperServiceState.inactive,
      );
      expect(
        serviceStateFromScQuery(0, 'STATE : 2  START_PENDING'),
        HelperServiceState.inactive,
      );
    });
  });

  group('parseServiceBinPath / sameServiceBinaryPath', () {
    test('解析现网真实 sc qc 输出', () {
      expect(
        parseServiceBinPath(_realScQcOutput),
        r'C:\Users\bypassnro\Documents\Bettbox\BettboxHelperService.exe',
      );
    });

    test('带外层引号的路径剥引号', () {
      expect(
        parseServiceBinPath(
          'BINARY_PATH_NAME   : "C:\\Program Files\\Bettbox\\helper.exe"',
        ),
        r'C:\Program Files\Bettbox\helper.exe',
      );
    });

    test('输出里没有 BINARY_PATH_NAME → null（调用方按指向别处处理）', () {
      expect(parseServiceBinPath('[SC] OpenService FAILED 1060'), isNull);
    });

    test('规范化：引号、斜杠、大小写、首尾空白都不影响比较', () {
      expect(
        sameServiceBinaryPath(
          r'"C:\Program Files\Bettbox\Helper.exe"',
          r'c:/program files/bettbox/helper.exe',
        ),
        isTrue,
      );
      expect(
        sameServiceBinaryPath(r'C:\A\Helper.exe', r'C:\B\Helper.exe'),
        isFalse,
      );
      expect(
        sameServiceBinaryPath(
          '$_realScQcOutput\n',
          r'C:\Users\bypassnro\Documents\Bettbox\BettboxHelperService.exe  ',
        ),
        isFalse,
        reason: '整段输出不是路径，只有解析后的值参与比较',
      );
      expect(
        sameServiceBinaryPath(
          parseServiceBinPath(_realScQcOutput)!,
          r'C:\Users\bypassnro\Documents\Bettbox\BettboxHelperService.exe',
        ),
        isTrue,
      );
    });
  });

  group('HelperServiceQuery.fromCliData', () {
    test('合法载荷映射到状态与标志位', () {
      final query = HelperServiceQuery.fromCliData({
        'state': 'running',
        'binPath': r'C:\Bettbox\helper.exe',
        'hasLegacyEnvironmentKey': true,
        'isStopped': false,
      });
      expect(query, isNotNull);
      expect(query!.state, HelperServiceState.running);
      expect(query.binPath, r'C:\Bettbox\helper.exe');
      expect(query.hasLegacyEnvironmentKey, isTrue);
      expect(query.isStopped, isFalse);
      expect(query.fromFallback, isFalse);
    });

    test('missing：binPath null、无遗留 key、非 stopped', () {
      final query = HelperServiceQuery.fromCliData({
        'state': 'missing',
        'binPath': null,
        'hasLegacyEnvironmentKey': false,
        'isStopped': false,
      });
      expect(query!.state, HelperServiceState.missing);
      expect(query.binPath, isNull);
    });

    test('inactive 且 isStopped=true 供等待健康识别「已停」', () {
      final query = HelperServiceQuery.fromCliData({
        'state': 'inactive',
        'binPath': r'C:\A\helper.exe',
        'hasLegacyEnvironmentKey': false,
        'isStopped': true,
      });
      expect(query!.state, HelperServiceState.inactive);
      expect(query.isStopped, isTrue);
    });

    test('data 缺失或 state 非法 → null（调用方回退）', () {
      expect(HelperServiceQuery.fromCliData(null), isNull);
      expect(HelperServiceQuery.fromCliData({'state': 'weird'}), isNull);
      expect(HelperServiceQuery.fromCliData({}), isNull);
    });
  });

  group('serviceBinPathDiffersFromQuery', () {
    test('null（拿不到 binPath）按指向别处处理', () {
      expect(serviceBinPathDiffersFromQuery(null), isTrue);
    });
  });

  group('probeHelperPingWithRetry', () {
    test('healthy / incompatible 是确定性结论：不重试', () async {
      var calls = 0;
      Future<HelperPingStatus> probe() async {
        calls++;
        return HelperPingStatus.healthy;
      }

      expect(
        await probeHelperPingWithRetry(probe, delay: Duration.zero),
        HelperPingStatus.healthy,
      );
      expect(calls, 1);

      calls = 0;
      Future<HelperPingStatus> incompatibleProbe() async {
        calls++;
        return HelperPingStatus.incompatible;
      }

      expect(
        await probeHelperPingWithRetry(incompatibleProbe, delay: Duration.zero),
        HelperPingStatus.incompatible,
      );
      expect(calls, 1);
    });

    test('unreachable 瞬时失败后恢复 → 重试命中 healthy', () async {
      final results = [HelperPingStatus.unreachable, HelperPingStatus.healthy];
      var calls = 0;
      Future<HelperPingStatus> probe() async {
        calls++;
        return results[calls - 1];
      }

      expect(
        await probeHelperPingWithRetry(probe, delay: Duration.zero),
        HelperPingStatus.healthy,
      );
      expect(calls, 2);
    });

    test('authFailed 也重试，三轮耗尽后如实返回最后一轮结果', () async {
      final results = [
        HelperPingStatus.authFailed,
        HelperPingStatus.unreachable,
        HelperPingStatus.unreachable,
      ];
      var calls = 0;
      Future<HelperPingStatus> probe() async {
        calls++;
        return results[calls - 1];
      }

      expect(
        await probeHelperPingWithRetry(probe, delay: Duration.zero),
        HelperPingStatus.unreachable,
      );
      expect(calls, 3);
    });
  });
}
