import 'dart:collection';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/key_pattern.dart';
import 'package:test/test.dart';

/// `in_array` on values nested very deep and on values that contain
/// themselves.
///
/// The other values are the leaves of Laravel's `Arr::dot` whose key
/// matches the rule's parameter by `Str::is`, where a `*` is any text, dots
/// included (`validateInArray`, `ValidatesAttributes.php` at v13.40.0,
/// lines 1585-1598). So `others.*` takes every leaf below `others`, however
/// deep, and the walk has to read all of it. It called itself for every
/// level and wrote a dotted key at each one: a value some 8 000 levels deep
/// overflowed the stack, and so did one that contains itself. It now keeps
/// its own stack and writes a key only where a leaf needs one.
///
/// A list or map met again inside itself is not walked again and gives no
/// value. A PHP array is a value and cannot contain itself, so Laravel has
/// no answer there; this is the rule chosen here.
///
/// What the walk finds is compared with the walk as it was, kept below as
/// [_leavesBefore], for both of its modes (`distinct` uses the other one,
/// where a `*` is one key).
void main() {
  // [depth] lists, one in the other, the innermost holding [leaf]. Built
  // with a loop, not recursion.
  List<Object?> nestedList(int depth, [Object? leaf = 1]) {
    var value = <Object?>[leaf];
    for (var i = 1; i < depth; i++) {
      value = <Object?>[value];
    }
    return value;
  }

  Map<String, Object?> nestedMap(int depth, [Object? leaf = 1]) {
    var value = <String, Object?>{'v': leaf};
    for (var i = 1; i < depth; i++) {
      value = <String, Object?>{'v': value};
    }
    return value;
  }

  // Whether `in_array:[other]` finds [value] in [data].
  Future<bool> found(
    Object? value,
    Map<String, Object?> data,
    String other,
  ) async => (await Validator(
    {...data, 'value': value},
    {'value': 'in_array:$other'},
  ).run()).isEmpty;

  group('deep values', () {
    for (final depth in [8000, 20000, 50000]) {
      test(
        '$depth levels: no error, the leaf at the bottom is found',
        () async {
          for (final deep in [
            nestedList(depth, 'leaf'),
            nestedMap(depth, 'leaf'),
          ]) {
            final data = {
              'others': [deep, 'beside'],
            };
            expect(await found('leaf', data, 'others.*'), isTrue);
            expect(await found('beside', data, 'others.*'), isTrue);
            expect(await found('absent', data, 'others.*'), isFalse);
            // The deep value itself is a list or map, never one of the
            // leaves.
            expect(await found(deep, data, 'others.*'), isFalse);
            // A pattern that names where the walk must end still matches the
            // whole key.
            expect(await found('leaf', data, 'others.1'), isFalse);
            expect(await found('beside', data, 'others.1'), isTrue);
          }
        },
      );
    }

    test('items checked against themselves, each one deep', () async {
      final errors = await Validator(
        {
          'items': [nestedList(20000), nestedList(20000), 1],
        },
        {'items.*': 'in_array:items.*'},
      ).run();
      // The lists are not leaves; the 1 is one, and the one at the bottom
      // of each list too.
      expect(errors.keys.toSet(), {'items.0', 'items.1'});
    });

    test('a leaf at every level', () async {
      // [0, [1, [2, ...]]]: every number is a leaf.
      Object? value = <Object?>[2999];
      for (var i = 2998; i >= 0; i--) {
        value = <Object?>[i, value];
      }
      final data = {'others': value};
      expect(await found(0, data, 'others.*'), isTrue);
      expect(await found(2999, data, 'others.*'), isTrue);
      expect(await found(3000, data, 'others.*'), isFalse);
      // `others.0` is the first number only; `others.1.0` the second.
      expect(await found(0, data, 'others.0'), isTrue);
      expect(await found(1, data, 'others.0'), isFalse);
      expect(await found(1, data, 'others.1.0'), isTrue);
      expect(await found(1500, data, 'others.*.0'), isTrue);
    });
  });

  // The lists and maps here stop the test after a number of reads, so that
  // a walk which goes round a cycle fails instead of running for ever.
  group('values that contain themselves', () {
    test('a list that contains itself', () async {
      final list = _BudgetList(['a', null, 'b']);
      list.items[1] = list;
      final data = {'others': list};
      expect(await found('a', data, 'others.*'), isTrue);
      expect(await found('b', data, 'others.*'), isTrue);
      expect(await found('c', data, 'others.*'), isFalse);
      expect(await found(list, data, 'others.*'), isFalse);
    });

    test('a map that contains itself', () async {
      final map = _BudgetMap({'id': 7});
      map.entriesOf['self'] = map;
      map.entriesOf['last'] = 8;
      final data = {
        'others': {'a': map},
      };
      expect(await found(7, data, 'others.*'), isTrue);
      expect(await found(8, data, 'others.*'), isTrue);
      expect(await found(7, data, 'others.a.id'), isTrue);
      expect(await found(9, data, 'others.*'), isFalse);
    });

    test('met again inside itself, it gives no value', () async {
      final map = _BudgetMap({'id': 7});
      map.entriesOf['self'] = map;
      final data = {
        'others': {'a': map},
      };
      // The 7 is at `others.a.id` only: the map is not walked again at
      // `others.a.self`, so nothing is at `others.a.self.id`.
      expect(await found(7, data, 'others.a.self.id'), isFalse);
      expect(await found(7, data, 'others.*.self.*'), isFalse);
      expect(await found(7, data, 'others.a.*'), isTrue);
    });

    test('a cycle through two lists', () async {
      final a = _BudgetList(['a', null]);
      final b = _BudgetList(['b', a]);
      a.items[1] = b;
      final data = {
        'others': [a],
      };
      expect(await found('a', data, 'others.*'), isTrue);
      expect(await found('b', data, 'others.*'), isTrue);
      expect(await found('b', data, 'others.0.1.0'), isTrue);
      // `a` again, inside `b` inside `a`: not walked.
      expect(await found('a', data, 'others.0.1.1.0'), isFalse);
      expect(await found('c', data, 'others.*'), isFalse);
    });

    test('a list that contains itself twice', () async {
      final list = _BudgetList([null, 'x', null]);
      list.items[0] = list;
      list.items[2] = list;
      expect(await found('x', {'others': list}, 'others.*'), isTrue);
      expect(await found('y', {'others': list}, 'others.*'), isFalse);
    });

    test('the input itself inside the input', () {
      final data = _BudgetMap({
        'others': [1, 2],
      });
      data.entriesOf['again'] = data;
      bool finds(Object? value, String other) =>
          InArrayRule(other).passes(
            ValidationContext(
              attribute: 'value',
              pattern: 'value',
              value: value,
              present: true,
              data: data,
            ),
          ) ==
          null;
      expect(finds(2, 'others.*'), isTrue);
      expect(finds(2, '*'), isTrue);
      expect(finds(2, 'again.others.*'), isFalse);
      expect(finds(3, '*'), isFalse);
    });

    test('met twice side by side, it is walked twice', () async {
      final shared = _BudgetList(['s']);
      final data = {
        'others': [shared, shared],
      };
      expect(await found('s', data, 'others.0.*'), isTrue);
      expect(await found('s', data, 'others.1.*'), isTrue);
      // One level down again, on another path: still not inside itself.
      final outer = {
        'others': [
          [shared],
          {'k': shared},
        ],
      };
      expect(await found('s', outer, 'others.0.0.0'), isTrue);
      expect(await found('s', outer, 'others.1.k.0'), isTrue);
    });
  });

  group('the same leaves as the walk before', () {
    // What the rules read is compared, value by value, with the leaves of
    // [_leavesBefore]. Every leaf of the trees below holds a value of its
    // own (or an empty list or map), so asking for each value tells which
    // leaves a walk took, and which one won where two share a key.
    //
    // `in_array` reads the walk where a `*` crosses dots: a value is found
    // exactly when it is one of the leaves.
    void sameCrossing(Map<String, Object?> data, String pattern) {
      final before = _leavesBefore(data, pattern, crossDots: true);
      final rule = InArrayRule(pattern);
      bool finds(Object? value) =>
          rule.passes(
            ValidationContext(
              attribute: 'probe',
              pattern: 'probe',
              value: value,
              present: true,
              data: data,
            ),
          ) ==
          null;
      final values = before.values.toSet();
      for (final value in _scalars(data)) {
        expect(
          finds(value),
          values.contains(value),
          reason: 'in_array:$pattern, $value in $data',
        );
      }
      expect(
        finds(<Object?>[]),
        before.values.any(
          (v) =>
              (v is List<Object?> && v.isEmpty) ||
              (v is Map<Object?, Object?> && v.isEmpty),
        ),
        reason: 'in_array:$pattern, an empty list in $data',
      );
    }

    // `distinct:strict` reads the walk where a `*` is one key: a value at
    // a key that is not a leaf is a duplicate exactly when it is one of
    // the leaves, and a leaf's own value at its own key is not one.
    void sameWithin(Map<String, Object?> data, String pattern) {
      final before = _leavesBefore(data, pattern, crossDots: false);
      const rule = DistinctRule(strict: true);
      bool duplicate(String attribute, Object? value) =>
          rule.passes(
            ValidationContext(
              attribute: attribute,
              pattern: pattern,
              value: value,
              present: true,
              data: data,
            ),
          ) !=
          null;
      final values = before.values.toSet();
      for (final value in _scalars(data)) {
        expect(
          duplicate('#no such key#', value),
          values.contains(value),
          reason: 'distinct $pattern, $value in $data',
        );
      }
      for (final MapEntry(:key, :value) in before.entries) {
        if (value is List<Object?> || value is Map<Object?, Object?>) {
          continue;
        }
        expect(
          duplicate(key, value),
          isFalse,
          reason: 'distinct $pattern, the key $key in $data',
        );
      }
    }

    void same(Map<String, Object?> data, String pattern) {
      sameCrossing(data, pattern);
      sameWithin(data, pattern);
    }

    const patterns = [
      '*',
      '*.*',
      'a.*',
      'a.*.b',
      'a.*.*',
      '*.a',
      '*.b.*',
      '*a',
      'a*',
      'a',
      'a.b',
      'a.0',
      '0.*',
      'a.0.*',
      '*.0',
      '',
      '.a',
      '.*',
      'a.',
      'a..b',
      'a.*.',
      '*.*.*',
      'a.b.*',
      'x*y',
      '**',
    ];

    test('handwritten trees', () {
      var n = 0;
      final trees = <Map<String, Object?>>[
        <String, Object?>{},
        {'a': ++n},
        {'a': <Object?>[]},
        {'a': <String, Object?>{}},
        {
          'a': [++n, ++n, <Object?>[], <String, Object?>{}],
        },
        // Keys with dots: the same dotted key by two ways, the later wins.
        {
          'a.b': ++n,
          'a': {'b': ++n},
        },
        {
          'a': {'b': ++n},
          'a.b': ++n,
        },
        {
          'a': {
            'b.c': ++n,
            'b': {'c': ++n},
          },
        },
        {
          'a.0': [++n],
          'a': [
            [++n],
          ],
        },
        // Empty keys, at the root and below.
        {
          '': {'a': ++n},
          'a': ++n,
        },
        {'': ++n},
        {
          '': {
            '': {'': ++n},
          },
        },
        {
          'a': {'': ++n, 'b': ++n},
        },
        {
          'a': {
            '': {'b': ++n},
          },
        },
        // Keys that are numbers, and a list beside a map.
        {
          'a': {'0': ++n, '1': ++n},
          '0': [++n, ++n],
        },
        {
          'a': [
            {'b': ++n},
            {'b': ++n, 'c': ++n},
            [++n, ++n],
          ],
        },
        // Keys with a `*`, a dot at an end, and text around the pattern's.
        {
          '*': ++n,
          'a': {'*': ++n, 'b.': ++n, '.b': ++n},
        },
        {'xay': ++n, 'ba': ++n, 'ab': ++n, 'x.y': ++n},
        {
          'a': {
            'b': {
              'c': {
                'd': {'e': ++n},
              },
            },
          },
        },
        {
          'a': [
            's${++n}',
            1.5 + ++n,
            [
              [
                ['t${++n}'],
              ],
            ],
          ],
        },
      ];
      for (final data in trees) {
        for (final pattern in patterns) {
          same(data, pattern);
        }
      }
    });

    test('6 000 seeded random trees', () {
      final random = Random(20261127);
      const names = ['a', 'b', '0', '1', '', 'a.b', '.', 'b.', '*', 'xay'];
      var n = 0;
      Object? node(int depth) {
        final roll = random.nextInt(10);
        if (depth >= 5 || roll < 4) {
          return switch (random.nextInt(12)) {
            0 => <Object?>[],
            1 => <String, Object?>{},
            2 => 's${++n}',
            _ => ++n,
          };
        }
        if (roll < 7) {
          return [for (var i = random.nextInt(4); i > 0; i--) node(depth + 1)];
        }
        return {
          for (var i = random.nextInt(4); i > 0; i--)
            names[random.nextInt(names.length)]: node(depth + 1),
        };
      }

      var leaves = 0;
      for (var i = 0; i < 6000; i++) {
        final data = <String, Object?>{
          for (var k = random.nextInt(4); k >= 0; k--)
            names[random.nextInt(names.length)]: node(1),
        };
        for (var p = 0; p < 3; p++) {
          final pattern = patterns[random.nextInt(patterns.length)];
          same(data, pattern);
          leaves += _leavesBefore(data, pattern, crossDots: true).length;
        }
      }
      // The patterns do match: the comparison is not of nothing.
      expect(leaves, greaterThan(15000));
    });

    test('the validator decides the same', () async {
      final random = Random(20261128);
      for (var i = 0; i < 300; i++) {
        var n = 0;
        final data = <String, Object?>{
          'a': [
            for (var j = random.nextInt(5); j > 0; j--)
              random.nextBool()
                  ? ++n
                  : {
                      'b': ++n,
                      'c': [++n, ++n],
                    },
          ],
          'a.x': ++n,
        };
        for (final pattern in ['a.*', 'a.*.b', 'a.*.c.*', '*', 'a.0']) {
          final values = _leavesBefore(
            data,
            pattern,
            crossDots: true,
          ).values.toSet();
          final probes = [for (var v = 0; v <= n + 1; v++) v];
          final errors = await Validator(
            {...data, 'probes': probes},
            {'probes.*': 'in_array:$pattern'},
          ).run();
          // `*` also takes the probes themselves, which are in the input.
          final all = pattern == '*' ? {...values, ...probes} : values;
          expect(errors.keys.toSet(), {
            for (var v = 0; v < probes.length; v++)
              if (!all.contains(probes[v])) 'probes.$v',
          }, reason: 'in_array:$pattern in $data');
        }
      }
    });
  });

  group('the cost', () {
    // One walk, without the validator around it.
    int micros(Map<String, Object?> data, String other) {
      final rule = InArrayRule(other);
      final context = ValidationContext(
        attribute: 'value',
        pattern: 'value',
        value: 'absent',
        present: true,
        data: data,
      );
      var best = 1 << 62;
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        rule.passes(context);
        best = min(best, watch.elapsedMicroseconds);
      }
      return best;
    }

    // Growth, not a wall-clock bound. Eight times the depth is eight times
    // the work when one key is written, at the leaf; a key written at every
    // level is text growing with the square of the depth, 64 times.
    for (final (name, chain) in <(String, Object? Function(int))>[
      ('lists', nestedList),
      ('maps', nestedMap),
    ]) {
      test('a chain of $name: linear in its depth', () {
        micros({'others': chain(500)}, 'others.*');
        final small = micros({'others': chain(2000)}, 'others.*');
        final large = micros({'others': chain(16000)}, 'others.*');
        expect(
          large / max(small, 1),
          lessThan(30),
          reason: '2 000 levels: $small us, 16 000: $large us',
        );
      });
    }

    // 16 000 items over 1 000, as `in_array_linear_test.dart`: linear is
    // about 16.
    for (final (name, other, item) in <(String, String, Object? Function(int))>[
      ('numbers', 'others.*', (i) => i),
      ('maps', 'others.*.id', (i) => {'id': i, 'name': 'n$i'}),
      (
        'lists in maps',
        'others.*.tags.*',
        (i) => {
          'tags': [i, -i - 1],
        },
      ),
    ]) {
      test('a wide list of $name: linear in its length', () {
        Map<String, Object?> data(int n) => {
          'others': [for (var i = 0; i < n; i++) item(i)],
        };
        micros(data(100), other);
        final small = micros(data(1000), other);
        final large = micros(data(16000), other);
        expect(
          // Under 5 ms the ratio is timer noise: linear either way.
          large < 5000 || large / max(small, 1) < 100,
          isTrue,
          reason: '1 000: $small us, 16 000: $large us',
        );
      });
    }
  });
}

/// The numbers and strings anywhere in [data], with no recursion limit to
/// mind: the trees of the comparison are a few levels deep.
Set<Object?> _scalars(Object? data) => switch (data) {
  final List<Object?> list => {for (final item in list) ..._scalars(item)},
  final Map<Object?, Object?> map => {
    for (final item in map.values) ..._scalars(item),
  },
  _ => {data},
};

/// The walk as it was before it kept its own stack (`_leavesMatching` in
/// `rules.dart` at 1f95bd98), copied unchanged: the reference of the
/// comparison. It calls itself for every level and writes a path at each.
Map<String, Object?> _leavesBefore(
  Map<String, Object?> data,
  String pattern, {
  required bool crossDots,
}) {
  final keys = KeyPattern(pattern, crossDots: crossDots);
  final leaves = <String, Object?>{};
  final deepest = crossDots ? null : pattern.split('.').length;
  void walk(Object? node, String? path, int depth) {
    final descend = deepest == null || depth < deepest;
    switch (node) {
      case Map<Object?, Object?>() when node.isNotEmpty:
        if (descend) {
          for (final MapEntry(:key, :value) in node.entries) {
            walk(value, path == null ? '$key' : '$path.$key', depth + 1);
          }
        }
      case List<Object?>() when node.isNotEmpty:
        if (descend) {
          for (var i = 0; i < node.length; i++) {
            walk(node[i], path == null ? '$i' : '$path.$i', depth + 1);
          }
        }
      default:
        final key = path ?? '';
        if (keys.matches(key)) {
          leaves[key] = node;
        }
    }
  }

  walk(data, null, 0);
  return leaves;
}

/// A list that fails the test once it has been read too often: a walk that
/// goes round a cycle ends in an error, not in a loop without end.
final class _BudgetList extends ListBase<Object?> {
  _BudgetList(this.items);

  final List<Object?> items;
  int _reads = 0;

  @override
  int get length => items.length;

  @override
  set length(int _) => throw UnsupportedError('fixed');

  @override
  Object? operator [](int index) {
    if (++_reads > 10000) {
      throw StateError('read $_reads times: walked round a cycle');
    }
    return items[index];
  }

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('fixed');
}

/// A map with the same budget of reads as [_BudgetList].
final class _BudgetMap extends MapBase<String, Object?> {
  _BudgetMap(this.entriesOf);

  final Map<String, Object?> entriesOf;
  int _reads = 0;

  @override
  bool get isEmpty => entriesOf.isEmpty;

  @override
  bool get isNotEmpty => entriesOf.isNotEmpty;

  @override
  int get length => entriesOf.length;

  @override
  Iterable<String> get keys {
    if (++_reads > 10000) {
      throw StateError('read $_reads times: walked round a cycle');
    }
    return entriesOf.keys;
  }

  @override
  Object? operator [](Object? key) => entriesOf[key];

  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('fixed');

  @override
  void clear() => throw UnsupportedError('fixed');

  @override
  Object? remove(Object? key) => throw UnsupportedError('fixed');
}
