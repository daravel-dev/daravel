import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

/// A placeholder of the validator (`__dot__<hash>`, `__asterisk__<hash>`,
/// or the same with `_` written as spaces, as a display name shows it).
final _placeholder = RegExp(r'(__|  )(dot|asterisk)(__|  )[a-z]{16}');

/// What the rules see and say when a key of the input is empty, holds a
/// `.` or a `*`, or is a list index written another way.
void main() {
  group('an empty key is a key at every level of a wildcard', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) => router
              ..post(
                '/top',
                (request) async =>
                    (await request.validate({'*.role': 'in:user'})).toMap(),
              )
              ..post(
                '/two',
                (request) async =>
                    (await request.validate({'*.*.role': 'in:user'})).toMap(),
              )
              ..post(
                '/inner',
                (request) async =>
                    (await request.validate({'a.*.*.b': 'in:user'})).toMap(),
              ),
          )
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    Future<(int, Object?)> send(String path, Object body) async {
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: path,
          json: body,
          headers: {'accept': 'application/json'},
        ),
      );
      return (response.status, jsonDecode(await response.bodyText()));
    }

    Object? errors(Object? body) => (body! as Map<String, Object?>)['errors'];

    test('*.role checks the role under the empty key', () async {
      final (status, body) = await send('/top', {
        '': {'role': 'admin'},
      });
      expect(status, 422);
      expect(errors(body), {
        '.role': ['The selected .role is invalid.'],
      });
      expect(
        (await send('/top', {
          '': {'role': 'user'},
        })).$1,
        200,
      );
    });

    test('*.*.role checks it under two empty keys, and under one', () async {
      for (final (data, key) in [
        (
          {
            '': {
              '': {'role': 'admin'},
            },
          },
          '..role',
        ),
        (
          {
            '': {
              'x': {'role': 'admin'},
            },
          },
          '.x.role',
        ),
        (
          {
            'x': {
              '': {'role': 'admin'},
            },
          },
          'x..role',
        ),
      ]) {
        final (status, body) = await send('/two', data);
        expect(status, 422, reason: key);
        expect((errors(body)! as Map).keys, [key]);
      }
    });

    test('a.*.*.b checks b under an empty key at either wildcard', () async {
      for (final (data, key) in [
        (
          {
            'a': {
              '': {
                'x': {'b': 'admin'},
              },
            },
          },
          'a..x.b',
        ),
        (
          {
            'a': {
              'x': {
                '': {'b': 'admin'},
              },
            },
          },
          'a.x..b',
        ),
        (
          {
            'a': {
              '': {
                '': {'b': 'admin'},
              },
            },
          },
          'a...b',
        ),
      ]) {
        final (status, body) = await send('/inner', data);
        expect(status, 422, reason: key);
        expect((errors(body)! as Map).keys, [key]);
      }
    });
  });

  group('no placeholder reaches a message or an error key', () {
    // Every rule the string form knows (the registry `dartisan lint`
    // checks rule names against), given a field under a dotted and under
    // a starred key as its parameter: a rule that reads it as a field
    // shows its display name, and none may show the placeholder.
    test('every registered rule, with another field as its parameter, '
        'under a key with a dot and one with an asterisk', () async {
      final swept = <String>[];
      final skipped = <String, String>{};
      for (final name in InvalidValidationRule.knownRules.toList()..sort()) {
        for (final key in ['a.b', 'x*y']) {
          final Rule rule;
          try {
            rule =
                _parse('$name:items.*.other') ??
                // `required_if:field,value` and the like.
                RuleParser.parseOne('$name:items.*.other,zzz');
          } on Object catch (e) {
            skipped[name] = '$e';
            continue;
          }
          for (final value in <Object?>[
            'abc',
            7,
            {'k.1': 1},
            null,
          ]) {
            final validator = Validator(
              {
                'items': {
                  key: {'v': value, 'other': 'zzz', 'v_confirmation': 'q'},
                },
              },
              {
                'items.*.v': [rule],
              },
            );
            final Map<String, List<String>> errors;
            try {
              errors = await validator.run();
            } on Object catch (e) {
              // Rules that need a service (a database for `exists`,
              // `unique`) or a file: nothing they could say.
              skipped[name] = '$e';
              break;
            }
            for (final MapEntry(key: k, value: messages) in errors.entries) {
              expect(k, isNot(matches(_placeholder)), reason: '$name $key');
              for (final message in messages) {
                expect(
                  message,
                  isNot(matches(_placeholder)),
                  reason: '$name $key $value',
                );
              }
            }
          }
          if (!skipped.containsKey(name)) {
            swept.add(name);
          }
        }
      }
      print(
        'swept ${swept.toSet().length} rules; skipped ${skipped.length}: '
        '${skipped.keys.join(', ')}',
      );
      expect(swept.toSet().length, greaterThan(80));
      // The rules that name another field are among those swept.
      expect(
        swept,
        containsAll(['same', 'different', 'confirmed', 'gt', 'required_if']),
      );
    });

    test('a message a Rule class writes from the attribute comes out as '
        'sent', () async {
      final errors = await Validator(
        {
          'items': {
            'a.b': {'v': 1},
            'x*y': {'v': 1},
          },
        },
        {
          'items.*.v': [const _NamesItself()],
        },
      ).run();
      expect(errors, {
        'items.a.b.v': ['items.a.b.v is wrong (items.a.b.v)'],
        'items.x*y.v': ['items.x*y.v is wrong (items.x*y.v)'],
      });
    });
  });

  group('every rule sees the attribute as sent', () {
    test('a Rule class and a closure get the same attribute, and both '
        'find other fields through root and sibling', () async {
      final seen = <String>[];
      await Validator(
        {
          'items': {
            'a.b': {'v': 1, 'w': 2},
          },
        },
        {
          'items.*.v': [
            _Records(seen),
            Rules.custom((c) {
              seen.add('closure ${c.attribute} ${c.sibling('w')}');
              return null;
            }),
          ],
        },
      ).run();
      expect(seen, ['class items.a.b.v 2 2', 'closure items.a.b.v 2']);
    });
  });

  group('rules that compare two whole values compare them in one form', () {
    final map = {'k.1': 1, 'n*': 2};

    Future<Map<String, List<String>>> run(
      Map<String, Object?> data,
      Object rules,
    ) => Validator(data, {'a': rules}).run();

    test('same and different over objects with dotted keys', () async {
      expect(
        await run({
          'a': map,
          'b': {...map},
        }, 'same:b'),
        isEmpty,
      );
      expect(
        (await run({
          'a': map,
          'b': {...map},
        }, 'different:b')).keys,
        ['a'],
      );
      expect(
        (await run({
          'a': map,
          'b': {'k.1': 9},
        }, 'same:b')).keys,
        ['a'],
      );
      expect(
        await run({
          'a': map,
          'b': {'k.1': 9},
        }, 'different:b'),
        isEmpty,
      );
    });

    test('confirmed over an object with dotted keys', () async {
      expect(
        await run({
          'a': map,
          'a_confirmation': {...map},
        }, 'confirmed'),
        isEmpty,
      );
      expect(
        (await run({
          'a': map,
          'a_confirmation': {'k.1': 1},
        }, 'confirmed')).keys,
        ['a'],
      );
    });

    test('in_array and distinct read leaves, which hold no key', () async {
      // Laravel's `Arr::dot` walks every non-empty array, so an object is
      // never one of the values compared: an object fails `in_array` and
      // `distinct` never sees it (`Arr.php` 12.x :184-206).
      expect(
        (await Validator(
          {
            'a': map,
            'list': [map],
          },
          {'a': 'in_array:list.*'},
        ).run()).keys,
        ['a'],
      );
      expect(
        await Validator(
          {
            'items': [map, map],
          },
          {'items.*': 'distinct'},
        ).run(),
        isEmpty,
      );
    });

    test('required_if with an object as the other field', () async {
      // The other value is compared with strings: an object never equals
      // one, in either form.
      expect(
        await Validator({'b': map}, {'a': 'required_if:b,k.1'}).run(),
        isEmpty,
      );
    });
  });

  group('a list index in a pattern is read in its canonical form only', () {
    final items = [
      {'name': 'one'},
      {'name': 'two'},
    ];

    test('a negative index matches nothing: 200, not 500', () async {
      final out = await Validator(
        {'items': items},
        {'items.-1.*': 'string', 'items.-1': 'required'},
      ).run();
      expect(out.keys, ['items.-1']);
    });

    test('01 is a key, not the index 1, in every lookup', () async {
      final validator = Validator(
        {'items': items},
        {'items.01.name': 'required'},
      );
      expect((await validator.run()).keys, ['items.01.name']);
      final out = await Validator(
        {'items': items},
        {'items.01.name': 'string', 'items.1.name': 'string'},
      ).validate();
      expect(out.toMap(), {
        'items': [
          null,
          {'name': 'two'},
        ],
      });
    });
  });
}

Rule? _parse(String dsl) {
  try {
    return RuleParser.parseOne(dsl);
  } on Object {
    return null;
  }
}

/// An application rule that fails with a message written from what it
/// is given: the attribute and its display name.
final class _NamesItself extends Rule {
  const _NamesItself();

  @override
  String get name => 'names_itself';

  @override
  String? passes(ValidationContext context) =>
      '${context.attribute} is wrong '
      '(${context.displayName(context.attribute)})';
}

/// An application rule that records what it sees.
final class _Records extends Rule {
  _Records(this.seen);

  final List<String> seen;

  @override
  String get name => 'records';

  @override
  String? passes(ValidationContext context) {
    seen.add(
      'class ${context.attribute} ${context.sibling('w')} '
      '${context.root('items.*.w')}',
    );
    return null;
  }
}
