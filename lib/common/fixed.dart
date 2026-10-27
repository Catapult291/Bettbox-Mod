import 'iterable.dart';

typedef ValueCallback<T> = T Function();

class FixedList<T> {
  final int maxLength;
  final List<T> _list;
  List<T>? _cachedList;

  FixedList(this.maxLength, {List<T>? list})
    : _list = (list ?? [])..truncate(maxLength);

  void add(T item) {
    _list.add(item);
    _trim();
    _cachedList = null;
  }

  /// 批量追加，裁剪只做一次。
  void addAll(Iterable<T> items) {
    if (items.isEmpty) {
      return;
    }
    _list.addAll(items);
    _trim();
    _cachedList = null;
  }

  void _trim() {
    if (maxLength == 0) {
      return;
    }
    final overflow = _list.length - maxLength;
    if (overflow > 0) {
      _list.removeRange(0, overflow);
    }
  }

  void clear() {
    _list.clear();
    _cachedList = null;
  }

  List<T> get list => _cachedList ??= List.unmodifiable(_list);

  int get length => _list.length;

  T operator [](int index) => _list[index];

  /// 新实例与原实例共享底层 list：写入只换引用（O(1)），读 [list] 时才复制快照。
  ///
  /// 每写一次就复制整表会让合帧写入（一次 50 条以上）比逐条写入还贵，而 [list]
  /// 返回的本来就是不可变副本，读到的内容不会随之后的写入改变。
  FixedList<T> copyWith() {
    return FixedList(maxLength, list: _list);
  }
}

class FixedMap<K, V> {
  int maxLength;
  late Map<K, V> _map;

  FixedMap(this.maxLength, {Map<K, V>? map}) {
    _map = map ?? {};
  }

  V updateCacheValue(K key, ValueCallback<V> callback) {
    final realValue = _map.updateCacheValue(key, callback);
    _adjustMap();
    return realValue;
  }

  void clear() {
    _map.clear();
  }

  void updateMaxLength(int size) {
    maxLength = size;
    _adjustMap();
  }

  void updateMap(Map<K, V> map) {
    _map = map;
    _adjustMap();
  }

  void _adjustMap() {
    if (_map.length > maxLength) {
      _map = Map.fromEntries(map.entries.toList()..truncate(maxLength));
    }
  }

  V? get(K key) => _map[key];

  bool containsKey(K key) => _map.containsKey(key);

  int get length => _map.length;

  Map<K, V> get map => Map.unmodifiable(_map);
}
