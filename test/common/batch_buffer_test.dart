import 'package:bett_box/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

const _interval = Duration(milliseconds: 30);
const _wait = Duration(milliseconds: 150);

void main() {
  test('窗口内的多次 add 合并成一次写出，顺序不变', () async {
    final flushed = <List<int>>[];
    final buffer = BatchBuffer<int>(flush: flushed.add, interval: _interval);

    buffer.add(1);
    buffer.add(2);
    buffer.addAll([3, 4]);
    buffer.addAll(const []);

    expect(flushed, isEmpty);
    expect(buffer.hasPending, isTrue);

    await Future<void>.delayed(_wait);

    expect(flushed, [
      [1, 2, 3, 4],
    ]);
    expect(buffer.hasPending, isFalse);
  });

  test('写出后再次 add 会重新开一个窗口', () async {
    final flushed = <List<int>>[];
    final buffer = BatchBuffer<int>(flush: flushed.add, interval: _interval);

    buffer.add(1);
    await Future<void>.delayed(_wait);
    buffer.add(2);
    await Future<void>.delayed(_wait);

    expect(flushed, [
      [1],
      [2],
    ]);
  });

  test('flushNow 立即写出并取消计时器', () async {
    final flushed = <List<int>>[];
    final buffer = BatchBuffer<int>(flush: flushed.add, interval: _interval);

    buffer.add(1);
    buffer.add(2);
    buffer.flushNow();

    expect(flushed, [
      [1, 2],
    ]);

    await Future<void>.delayed(_wait);
    expect(flushed.length, 1);
  });

  test('discard 丢弃待写条目，清空后不会再冒出旧条目', () async {
    final flushed = <List<int>>[];
    final buffer = BatchBuffer<int>(flush: flushed.add, interval: _interval);

    buffer.add(1);
    buffer.discard();

    expect(buffer.hasPending, isFalse);
    await Future<void>.delayed(_wait);
    expect(flushed, isEmpty);

    buffer.flushNow();
    expect(flushed, isEmpty);
  });
}
