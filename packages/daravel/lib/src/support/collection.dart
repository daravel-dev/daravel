import 'helpers.dart' show dataGet;

/// Laravel-collection style helpers on any `Iterable` (BLUEPRINT_V2 §7.12).
/// They complement `package:collection` rather than replace it, and work
/// directly on lists, sets, query results and model collections:
///
/// ```dart
/// final rows = await DB.table('users').get();
/// rows.pluck('email');                    // ['a@x.io', ...]
/// rows.keyBy((r) => r['id']);              // {1: {...}, 2: {...}}
/// users.groupBy((u) => u.role);           // {'admin': [...], ...}
/// users.chunk(100);                        // lists of 100
/// orders.sumBy((o) => o.total);
/// ```
extension DaravelIterable<T> on Iterable<T> {
  /// Values at [path] (dot notation) of maps, lists or models
  /// (`$collection->pluck('user.name')`).
  List<Object?> pluck(String path) => [
    for (final item in this) dataGet(item, path),
  ];

  /// Maps each item by [key]; later items win on duplicate keys.
  Map<K, T> keyBy<K>(K Function(T item) key) => {
    for (final item in this) key(item): item,
  };

  /// Groups items by [key], keeping their order.
  Map<K, List<T>> groupBy<K>(K Function(T item) key) {
    final groups = <K, List<T>>{};
    for (final item in this) {
      (groups[key(item)] ??= <T>[]).add(item);
    }
    return groups;
  }

  /// Consecutive lists of [size] items (the last may be shorter).
  Iterable<List<T>> chunk(int size) sync* {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    var current = <T>[];
    for (final item in this) {
      current.add(item);
      if (current.length == size) {
        yield current;
        current = <T>[];
      }
    }
    if (current.isNotEmpty) {
      yield current;
    }
  }

  /// Items without duplicates (by value, or by the [by] selector), first
  /// occurrence kept.
  List<T> unique([Object? Function(T item)? by]) {
    final seen = <Object?>{};
    return [
      for (final item in this)
        if (seen.add(by == null ? item : by(item))) item,
    ];
  }

  /// Sum of [value] over the items.
  num sumBy(num Function(T item) value) =>
      fold<num>(0, (total, item) => total + value(item));

  /// Average of [value], or `null` when empty.
  double? avgBy(num Function(T item) value) =>
      isEmpty ? null : sumBy(value) / length;

  /// Items sorted ascending by [key] (stable).
  List<T> sortBy(Comparable<Object?> Function(T item) key) =>
      _sorted(key, descending: false);

  /// Items sorted descending by [key] (stable).
  List<T> sortByDesc(Comparable<Object?> Function(T item) key) =>
      _sorted(key, descending: true);

  List<T> _sorted(
    Comparable<Object?> Function(T item) key, {
    required bool descending,
  }) {
    final entries = [
      for (final (index, item) in indexed) (index, key(item), item),
    ];
    entries.sort((a, b) {
      final order = descending ? b.$2.compareTo(a.$2) : a.$2.compareTo(b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    return [for (final entry in entries) entry.$3];
  }

  /// Items passing and failing [test], in order.
  (List<T>, List<T>) partition(bool Function(T item) test) {
    final pass = <T>[];
    final fail = <T>[];
    for (final item in this) {
      (test(item) ? pass : fail).add(item);
    }
    return (pass, fail);
  }
}
