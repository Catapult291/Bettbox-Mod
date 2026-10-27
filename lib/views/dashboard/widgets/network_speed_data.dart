import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/app.dart';
import 'package:bett_box/widgets/line_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 曲线的两个起点，序列为空时只画它。
const _initPoints = [Point(0, 0), Point(1, 0)];

/// 网络速度卡片的两个数据出口：图表点序列与速率文案。
///
/// 卡片的每秒刷新来自流量数据本身，不是 tick；这里把「数据内容没变」翻译成
/// 「返回值没变」——`ref.watch` 拿到同一个列表实例（或同一个字符串）时不会
/// 通知，卡片也就不会重建。内核停止、或连接中无流量时，这正是每秒省掉的那次
/// 重建。
final networkSpeedPointsProvider =
    AutoDisposeNotifierProvider<NetworkSpeedPoints, List<Point>>(
      NetworkSpeedPoints.new,
    );

final networkSpeedTextProvider = AutoDisposeProvider<String>((ref) {
  final traffics = ref.watch(trafficsProvider.select((value) => value.list));
  return speedTextOf(traffics);
});

class NetworkSpeedPoints extends AutoDisposeNotifier<List<Point>> {
  List<Point>? _points;
  List<Traffic>? _source;

  @override
  List<Point> build() {
    final traffics = ref.watch(trafficsProvider.select((value) => value.list));
    final cached = _points;
    final source = _source;
    if (cached != null && source != null && _hasSameSpeeds(source, traffics)) {
      return cached;
    }
    _source = traffics;
    _points = buildSpeedPoints(traffics);
    return _points!;
  }

  /// 窗口里每个点的 y（速率）都没变时，图表画出来的形状与上一帧相同。
  bool _hasSameSpeeds(List<Traffic> previous, List<Traffic> next) {
    if (previous.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      final a = previous[i];
      final b = next[i];
      if (a.up != b.up || a.down != b.down) return false;
    }
    return true;
  }
}

/// 速率曲线：固定两个起点，后面接窗口里的每个速率。
List<Point> buildSpeedPoints(List<Traffic> traffics) {
  if (traffics.isEmpty) return _initPoints;

  final totalLength = traffics.length + _initPoints.length;
  final result = List<Point>.filled(totalLength, Point(0, 0));

  result[0] = _initPoints[0];
  result[1] = _initPoints[1];

  for (var i = 0; i < traffics.length; i++) {
    result[i + 2] = Point((i + 2).toDouble(), traffics[i].speed.toDouble());
  }

  return result;
}

/// 卡片右上角的速率文案；没有数据时按 0 速率显示。
String speedTextOf(List<Traffic> traffics) {
  if (traffics.isEmpty) return Traffic().toSpeedText();
  return traffics.last.toSpeedText();
}
