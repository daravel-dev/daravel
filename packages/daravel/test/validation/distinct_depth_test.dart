import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct` on values nested very deep, on values that contain
/// themselves, and on objects.
///
/// The values compared are the leaves of Laravel's `Arr::dot` whose key
/// matches the rule's pattern, each `*` one key (`extractDistinctValues`,
/// `ValidatesAttributes.php` at v13.40.0, lines 961-972). A list or map
/// that is not empty is walked, never compared, and nothing below the
/// pattern's last part can match: the walk stops there, whatever lies
/// deeper. It used to follow the input to the bottom, and a value some
/// 8 000 levels deep, or one that contains itself, overflowed the stack.
///
/// The deep cases are adapted from `distinct_strict_test.dart` of the 1.x
/// line. That line compares lists and maps by their content, up to a depth
/// of its own; here they are not among the values compared, so none of
/// them is ever a duplicate.
///
/// An object (an uploaded file) equals itself only: PHP's `===` of two
/// objects asks for the same instance (`in_array(..., true)`), and `==`
/// holds for the same instance too. Where PHP's `==` also takes two
/// instances of one class with equal properties for equal, two instances
/// are never equal here. Read from the source, not run in PHP.
void main() {
  const rules = <Object>[
    'distinct',
    'distinct:strict',
    'distinct:ignore_case',
    'distinct:strict,ignore_case',
  ];
  final both = {'items.0', 'items.1'};

  Future<Set<String>> failing(
    Object rule,
    List<Object?> items, [
    String pattern = 'items.*',
  ]) async =>
      (await Validator({'items': items}, {pattern: rule}).run()).keys.toSet();

  // [depth] lists, one in the other, the innermost holding [leaf]. Built
  // with a loop, not recursion.
  List<Object?> nestedList(int depth, [Object? leaf = 1]) {
    var value = <Object?>[leaf];
    for (var i = 1; i < depth; i++) {
      value = <Object?>[value];
    }
    return value;
  }

  Map<String, Object?> nestedMap(int depth) {
    var value = <String, Object?>{'v': 1};
    for (var i = 1; i < depth; i++) {
      value = <String, Object?>{'v': value};
    }
    return value;
  }

  List<Object?> selfList() {
    final list = <Object?>[1];
    list.add(list);
    return list;
  }

  Map<String, Object?> selfMap() {
    final map = <String, Object?>{'v': 1};
    map['m'] = map;
    return map;
  }

  // a contains b, b contains a.
  List<Object?> twoCycle() {
    final a = <Object?>['a'];
    final b = <Object?>['b', a];
    a.add(b);
    return a;
  }

  group('deep values', () {
    for (final depth in [8000, 20000, 50000]) {
      test('$depth levels: no error, never a duplicate', () async {
        for (final rule in rules) {
          expect(
            await failing(rule, [nestedList(depth), nestedList(depth)]),
            isEmpty,
            reason: '$rule',
          );
          expect(
            await failing(rule, [nestedMap(depth), nestedMap(depth)]),
            isEmpty,
            reason: '$rule',
          );
          // The same instance twice is still a list, not a value compared.
          final same = nestedList(depth);
          expect(await failing(rule, [same, same]), isEmpty, reason: '$rule');
        }
      });
    }

    test('the values beside a deep one are still compared', () async {
      for (final rule in rules) {
        expect(await failing(rule, ['a', nestedList(20000), 'a', 'b']), {
          'items.0',
          'items.2',
        }, reason: '$rule');
        // Two wildcards: the leaves two keys down, and nothing below.
        expect(
          await failing(rule, [
            ['a', nestedList(20000)],
            ['b', 'a'],
          ], 'items.*.*'),
          {'items.0.0', 'items.1.1'},
          reason: '$rule',
        );
        expect(
          await failing(rule, [
            {'id': 'a', 'more': nestedMap(20000)},
            {'id': 'a'},
            {'id': nestedList(20000)},
          ], 'items.*.id'),
          {'items.0.id', 'items.1.id'},
          reason: '$rule',
        );
      }
    });

    test('a deep value under a key with a dot', () async {
      // The key `a.b` is two parts of the dotted key, as in Laravel.
      for (final rule in rules) {
        final errors = await Validator(
          {
            'items': {
              'a.b': nestedList(20000),
              'c': {'d': 'x'},
              'e': {'f': 'x'},
            },
          },
          {'items.*.*': rule},
        ).run();
        expect(errors.keys.toSet(), {'items.c.d', 'items.e.f'});
      }
    });
  });

  group('values that contain themselves', () {
    test('a list or map that contains itself', () async {
      for (final rule in rules) {
        expect(
          await failing(rule, [selfList(), selfList()]),
          isEmpty,
          reason: '$rule',
        );
        final list = selfList();
        expect(await failing(rule, [list, list]), isEmpty, reason: '$rule');
        expect(
          await failing(rule, [selfMap(), selfMap()]),
          isEmpty,
          reason: '$rule',
        );
        final map = selfMap();
        expect(await failing(rule, [map, map]), isEmpty, reason: '$rule');
      }
    });

    test('a list that contains itself twice, and a cycle of two', () async {
      List<Object?> wide() {
        final list = <Object?>[];
        list
          ..add(list)
          ..add(list);
        return list;
      }

      for (final rule in rules) {
        expect(await failing(rule, [wide(), wide()]), isEmpty, reason: '$rule');
        expect(
          await failing(rule, [twoCycle(), twoCycle()]),
          isEmpty,
          reason: '$rule',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('its own leaves at the pattern\'s depth are compared', () async {
      // `[1, self]`: under `items.*.*` the 1 is a value, the list is not.
      for (final rule in rules) {
        expect(await failing(rule, [selfList(), selfList()], 'items.*.*'), {
          'items.0.0',
          'items.1.0',
        }, reason: '$rule');
      }
    });
  });

  group('objects', () {
    UploadedFile file() => UploadedFile.fake.withContent('a.txt', 'x');

    test('an object equals itself only', () async {
      for (final rule in rules) {
        expect(await failing(rule, [file(), file()]), isEmpty, reason: '$rule');
        final same = file();
        expect(await failing(rule, [same, same]), both, reason: '$rule');
        expect(await failing(rule, [same, file(), same]), {
          'items.0',
          'items.2',
        }, reason: '$rule');
        final plain = Object();
        expect(await failing(rule, [plain, plain]), both, reason: '$rule');
        expect(
          await failing(rule, [Object(), Object()]),
          isEmpty,
          reason: '$rule',
        );
      }
    });

    test('in a map under a wildcard field', () async {
      for (final rule in rules) {
        expect(
          await failing(rule, [
            {'file': file()},
            {'file': file()},
          ], 'items.*.file'),
          isEmpty,
          reason: '$rule',
        );
        final same = file();
        expect(
          await failing(rule, [
            {'file': same},
            {'file': same},
          ], 'items.*.file'),
          {'items.0.file', 'items.1.file'},
          reason: '$rule',
        );
      }
    });

    test('inside a list or map it is not a value compared', () async {
      final same = file();
      for (final rule in rules) {
        expect(
          await failing(rule, [
            {'file': same},
            {'file': same},
          ]),
          isEmpty,
          reason: '$rule',
        );
        expect(
          await failing(rule, [
            [same],
            [same],
          ]),
          isEmpty,
          reason: '$rule',
        );
      }
    });

    test('an object beside true, a number or a string', () async {
      final same = file();
      // `$object == true` in PHP, and `true == $object`.
      expect(await failing('distinct', [same, true]), both);
      expect(await failing('distinct:strict', [same, true]), isEmpty);
      for (final rule in rules) {
        expect(await failing(rule, [same, 'a', 2]), isEmpty, reason: '$rule');
      }
    });

    test('a class with its own == is still compared by instance', () async {
      for (final rule in rules) {
        expect(
          await failing(rule, [const _Always(), _Always.other()]),
          isEmpty,
          reason: '$rule',
        );
      }
    });

    test('records are never equal', () async {
      for (final rule in rules) {
        expect(await failing(rule, [(1, 2), (1, 2)]), isEmpty, reason: '$rule');
      }
    });

    test('in_array finds the same object, not another one', () async {
      Future<bool> found(Object? value, List<Object?> others) async =>
          (await Validator(
            {'value': value, 'others': others},
            {'value': 'in_array:others.*'},
          ).run()).isEmpty;
      final same = file();
      expect(await found(same, [1, same]), isTrue);
      expect(await found(same, [1, file()]), isFalse);
    });

    // Growth, not a wall-clock bound, as in `distinct_linear_test.dart`:
    // 16 000 objects over 1 000, each the fastest of three. Linear is
    // about 16; scanning the objects for every item was about 256.
    for (final rule in rules) {
      test('linear in the number of objects: $rule', () async {
        Future<int> fastest(int n) async {
          final data = {
            'items': [for (var i = 0; i < n; i++) Object()],
          };
          var best = 1 << 62;
          for (var i = 0; i < 3; i++) {
            final watch = Stopwatch()..start();
            final errors = await Validator(data, {'items.*': rule}).run();
            best = min(best, watch.elapsedMicroseconds);
            expect(errors, isEmpty);
          }
          return best;
        }

        await fastest(100);
        final small = await fastest(1000);
        final large = await fastest(16000);
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

/// Equal to every other instance by `==`, as a class may choose to be.
final class _Always {
  const _Always();
  _Always.other();

  @override
  bool operator ==(Object other) => other is _Always;

  @override
  int get hashCode => 0;
}
