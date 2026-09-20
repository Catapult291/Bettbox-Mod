import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/app.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/cupertino.dart';

class BaseNavigator {
  static Future<T?> push<T>(
    BuildContext context,
    Widget child, {
    bool maintainState = true,
  }) {
    return Navigator.of(
      context,
    ).push<T>(_buildRoute<T>(child, maintainState: maintainState));
  }

  /// 用 [child] 替换当前路由，被替换的那一页不再留在返回栈里。
  ///
  /// 用在「新页面是当前流程的延续、不该看到中间页」的场景，例如扫码成功后直接
  /// 换成导入页（先退再推会让人看到上一页一闪而过）。[context] 必须位于要被替换
  /// 的那条路由里。
  static Future<T?> replaceWith<T>(
    BuildContext context,
    Widget child, {
    bool maintainState = true,
  }) {
    return Navigator.of(context).pushReplacement<T, dynamic>(
      _buildRoute<T>(child, maintainState: maintainState),
    );
  }

  static Route<T> _buildRoute<T>(Widget child, {bool maintainState = true}) {
    if (globalState.appState.viewMode != ViewMode.mobile) {
      return CommonDesktopRoute<T>(
        builder: (context) => child,
        maintainState: maintainState,
      );
    }
    return _CleanCupertinoPageRoute<T>(
      builder: (context) => child,
      maintainState: maintainState,
    );
  }
}

class _CleanCupertinoPageRoute<T> extends CupertinoPageRoute<T> {
  _CleanCupertinoPageRoute({
    required super.builder,
    super.title,
    super.settings,
    super.fullscreenDialog,
    super.maintainState,
  }) : super(allowSnapshotting: false);

  @override
  Color? get barrierColor => null;
}

class CommonDesktopRoute<T> extends PageRoute<T> {
  final Widget Function(BuildContext context) builder;

  CommonDesktopRoute({
    required this.builder,
    this.maintainState = true,
  });

  @override
  final bool maintainState;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final Widget result = builder(context);
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: FadeTransition(opacity: animation, child: result),
    );
  }

  @override
  Duration get transitionDuration => Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => Duration(milliseconds: 200);
}
