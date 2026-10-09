import 'package:bett_box/common/system_proxy.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyManager extends ConsumerStatefulWidget {
  final Widget child;

  const ProxyManager({super.key, required this.child});

  @override
  ConsumerState createState() => _ProxyManagerState();
}

class _ProxyManagerState extends ConsumerState<ProxyManager> {
  /// 串行化启停：Windows 侧「开启」要先还原旧快照、再抓新快照，中间有 prefs 往返，
  /// 状态快速翻转时（内核启动中途又停止）两步会互相插队，可能出现「界面已关、
  /// 系统代理还开着」。`SystemProxy` 的入口自己吞掉错误，所以这条链不会因异常中断。
  Future<void> _pending = Future.value();

  void _schedule(Future<void> Function() action) {
    _pending = _pending.then((_) => action());
  }

  void _updateProxy(ProxyState proxyState) {
    final isStart = proxyState.isStart;
    final systemProxy = proxyState.systemProxy;
    final port = proxyState.port;
    if (isStart && systemProxy) {
      _schedule(
        () => SystemProxy.enable(port: port, bypass: proxyState.bypassDomain),
      );
    } else {
      _schedule(SystemProxy.disable);
    }
  }

  @override
  void initState() {
    super.initState();
    ref.listenManual(proxyStateProvider, (prev, next) {
      if (prev != next) {
        _updateProxy(next);
      }
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
