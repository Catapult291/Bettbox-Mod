import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'fixed.dart';

/// 合帧窗口：窗口内的条目合并成一次写出。
const batchInterval = Duration(milliseconds: 100);

/// 高频条目的合帧缓冲。
///
/// [add] 只入队，最多每 [interval] 写出一次；日志与连接事件可达每秒数百条，
/// 逐条写 provider 会各自复制一次列表快照、各通知一次整表，这里合并成一次。
class BatchBuffer<T> {
  BatchBuffer({required this.flush, this.interval = batchInterval});

  final void Function(List<T> items) flush;
  final Duration interval;

  final List<T> _pending = [];
  Timer? _timer;

  bool get hasPending => _pending.isNotEmpty;

  void add(T item) {
    _pending.add(item);
    _timer ??= Timer(interval, flushNow);
  }

  void addAll(Iterable<T> items) {
    if (items.isEmpty) {
      return;
    }
    _pending.addAll(items);
    _timer ??= Timer(interval, flushNow);
  }

  /// 立即写出待处理条目；没有待处理条目时什么都不做。
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) {
      return;
    }
    final items = List<T>.of(_pending);
    _pending.clear();
    flush(items);
  }

  /// 丢弃待处理条目，用于清空列表：清空后不该再冒出清空前入队的条目。
  void discard() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}

/// 给 `FixedList` 类型的 notifier 加合帧写入。
///
/// 一次 flush 只做一次 `copyWith` + `addAll` 与一次状态通知。
mixin FixedListBatchMixin<T> on AutoDisposeNotifier<FixedList<T>> {
  late final BatchBuffer<T> _batch = BatchBuffer<T>(flush: _writeBatch);

  void addBatched(T value) => _batch.add(value);

  /// 写出待处理条目，用于需要读最新内容之前（如导出日志）。
  void flushBatch() => _batch.flushNow();

  void discardBatch() => _batch.discard();

  void _writeBatch(List<T> items) {
    state = state.copyWith()..addAll(items);
  }
}
