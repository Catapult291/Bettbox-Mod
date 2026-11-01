import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 下发内核的运行期参数：进程分流启用时内核必须跑在规则模式并解析进程，
/// 否则进程例外在全局 / 直连模式下整体失效。
Config _config({
  required ProcessAccessProps access,
  Mode mode = Mode.global,
  FindProcessMode findProcessMode = FindProcessMode.off,
}) {
  return Config(
    themeProps: defaultThemeProps,
    patchClashConfig: defaultClashConfig.copyWith(
      mode: mode,
      findProcessMode: findProcessMode,
    ),
    processAccess: access,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await preferences.sharedPreferencesCompleter.future;
  });

  ProviderContainer container() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 常驻监听，避免 autoDispose 每次读取都重建。
    container.listen(updateParamsProvider, (_, _) {}, fireImmediately: true);
    return container;
  }

  test('白名单非空：出站模式下发为规则、强制查找进程', () {
    globalState.config = _config(
      access: const ProcessAccessProps(
        mode: ProcessAccessMode.whitelist,
        paths: [r'C:\apps\a.exe'],
      ),
    );
    final params = container().read(updateParamsProvider);
    expect(params.mode, Mode.rule);
    expect(params.findProcessMode, FindProcessMode.always);
  });

  test('黑名单非空：同样接管出站模式', () {
    globalState.config = _config(
      mode: Mode.direct,
      access: const ProcessAccessProps(
        mode: ProcessAccessMode.blacklist,
        paths: [r'C:\apps\a.exe'],
      ),
    );
    final params = container().read(updateParamsProvider);
    expect(params.mode, Mode.rule);
    expect(params.findProcessMode, FindProcessMode.always);
  });

  test('关闭进程分流：沿用用户选的模式与查找进程开关', () {
    globalState.config = _config(
      mode: Mode.global,
      access: const ProcessAccessProps(
        mode: ProcessAccessMode.whitelist,
        paths: [r'C:\apps\a.exe'],
      ),
    );
    final c = container();
    expect(c.read(updateParamsProvider).mode, Mode.rule);

    c
        .read(processAccessStateProvider.notifier)
        .updateState((state) => state.copyWith(mode: ProcessAccessMode.off));
    expect(c.read(updateParamsProvider).mode, Mode.global);
    expect(c.read(updateParamsProvider).findProcessMode, FindProcessMode.off);
  });

  test('模式开着但名单为空：不接管出站模式', () {
    globalState.config = _config(
      access: const ProcessAccessProps(mode: ProcessAccessMode.blacklist),
    );
    final params = container().read(updateParamsProvider);
    expect(params.mode, Mode.global);
    expect(params.findProcessMode, FindProcessMode.off);
  });

  test('启用后切换出站模式，下发值仍是规则模式', () {
    globalState.config = _config(
      access: const ProcessAccessProps(
        mode: ProcessAccessMode.whitelist,
        paths: [r'C:\apps\a.exe'],
      ),
    );
    final c = container();
    c
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith(mode: Mode.direct));
    expect(c.read(updateParamsProvider).mode, Mode.rule);
    expect(
      c.read(updateParamsProvider).findProcessMode,
      FindProcessMode.always,
    );
  });
}
