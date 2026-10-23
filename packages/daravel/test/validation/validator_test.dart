import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

Future<Map<String, List<String>>> errorsOf(
  Map<String, Object?> data,
  Map<String, Object> rules, {
  String locale = 'en',
  Map<String, String> messages = const {},
  Map<String, String> attributes = const {},
}) => Validator(
  data,
  rules,
  locale: locale,
  messages: messages,
  attributes: attributes,
).run();

void main() {
  group('presence semantics', () {
    test('required, nullable, sometimes, bail and empty strings', () async {
      final errors = await errorsOf(
        {
          'a': '',
          'b': null,
          'c': ' ',
          'd': [],
          'f': 'x',
          'g': null,
          'h': 'abc',
        },
        {
          'a': 'required',
          'b': 'required',
          'c': 'required',
          'd': 'required',
          'e': 'required',
          'f': 'sometimes|email',
          'missing': 'sometimes|required',
          'g': 'nullable|email',
          'h': 'bail|email|min:10',
          'i': 'email', // absent → not validated
          'j': 'string', // absent
        },
      );
      expect(errors.keys, unorderedEquals(['a', 'b', 'c', 'd', 'e', 'f', 'h']));
      expect(errors['a'], ['The a field is required.']);
      expect(errors['h'], ['The h field must be a valid email address.']);
    });

    test(
      'empty strings skip non-implicit rules, null without nullable fails',
      () async {
        final errors = await errorsOf(
          {'email': '', 'name': null},
          {'email': 'email', 'name': 'string'},
        );
        expect(errors.keys, ['name']);
      },
    );
  });

  group('rule catalog', () {
    test('types and formats', () async {
      final errors = await errorsOf(
        {
          'int': '12',
          'bad_int': '1.5',
          'num': '3.14',
          'bool': 'true',
          'bad_bool': 'yes',
          'list': [1],
          'map': {'a': 1},
          'email': 'a@b.co',
          'bad_email': 'nope@',
          'url': 'https://x.test/p',
          'uuid': '123e4567-e89b-42d3-a456-426614174000',
          'ip': '10.0.0.1',
          'ipv6': '::1',
          'json': '{"a":1}',
          'alpha': 'Déjà',
          'alpha_dash': 'a-b_c1',
          'lower': 'abc',
          'ascii': 'héllo',
        },
        {
          'int': 'integer',
          'bad_int': 'integer',
          'num': 'numeric',
          'bool': 'boolean',
          'bad_bool': 'boolean',
          'list': 'array',
          'map': 'map',
          'email': 'email',
          'bad_email': 'email',
          'url': 'url',
          'uuid': 'uuid',
          'ip': 'ipv4',
          'ipv6': 'ipv6',
          'json': 'json',
          'alpha': 'alpha',
          'alpha_dash': 'alpha_dash',
          'lower': 'lowercase',
          'ascii': 'ascii',
        },
      );
      expect(
        errors.keys,
        unorderedEquals(['bad_int', 'bad_bool', 'bad_email', 'ascii']),
      );
    });

    test('sizes depend on the value type', () async {
      final errors = await errorsOf(
        {
          'n': 5,
          's': 'héllo',
          'l': [1, 2, 3],
          'between': 11,
          'size': 'abc',
          'digits': '1234',
        },
        {
          'n': 'min:6',
          's': 'max:4',
          'l': 'between:1,2',
          'between': 'between:1,10',
          'size': 'size:3',
          'digits': 'digits:4|digits_between:1,3',
        },
      );
      expect(errors['n'], ['The n field must be at least 6.']);
      expect(errors['s'], [
        'The s field must not be greater than 4 characters.',
      ]);
      expect(errors['l'], ['The l field must have between 1 and 2 items.']);
      expect(errors['between'], [
        'The between field must be between 1 and 10.',
      ]);
      expect(errors.containsKey('size'), isFalse);
      expect(errors['digits'], [
        'The digits field must be between 1 and 3 digits.',
      ]);
    });

    test('comparisons, sets, confirmation and dates', () async {
      final errors = await errorsOf(
        {
          'role': 'admin',
          'color': 'pink',
          'password': 'secret12',
          'password_confirmation': 'secret13',
          'a': 1,
          'b': 1,
          'start': '2026-01-01',
          'end': '2025-12-31',
          'prefix': 'xyz',
          'tags': ['a', 'b', 'a'],
        },
        {
          'role': 'in:admin,user',
          'color': 'in:red,blue',
          'password': 'confirmed',
          'a': 'same:b',
          'b': 'different:a',
          'start': 'date',
          'end': 'date|after:start',
          'prefix': 'starts_with:ab,cd',
          'tags.*': 'distinct',
        },
      );
      expect(
        errors.keys,
        unorderedEquals([
          'color',
          'password',
          'b',
          'end',
          'prefix',
          'tags.0',
          'tags.2',
        ]),
      );
      expect(errors['password'], [
        'The password field confirmation does not match.',
      ]);
      expect(errors['end'], ['The end field must be a date after start.']);
    });

    test('conditional requirements', () async {
      final errors = await errorsOf(
        {'type': 'company', 'other': 'x'},
        {
          'vat': 'required_if:type,company',
          'name': 'required_unless:type,person',
          'phone': 'required_with:other',
          'fax': 'required_without:nothing',
          'ok': 'required_without:other',
        },
      );
      expect(errors.keys, unorderedEquals(['vat', 'name', 'phone', 'fax']));
      expect(errors['vat'], [
        'The vat field is required when type is company.',
      ]);
    });

    test('password rule', () async {
      final errors = await errorsOf(
        {'p1': 'short', 'p2': 'longenough', 'p3': 'Long3nough!'},
        {
          'p1': [Rules.password()],
          'p2': [Rules.password(mixedCase: true, numbers: true, symbols: true)],
          'p3': [Rules.password(mixedCase: true, numbers: true, symbols: true)],
        },
      );
      expect(errors.keys, unorderedEquals(['p1', 'p2']));
      expect(errors['p2']!.first, contains('uppercase and one lowercase'));
    });
  });

  group('nested wildcards and validated data', () {
    test('expands items.*.id and reports concrete paths', () async {
      final data = {
        'items': [
          {'id': 1, 'qty': 2},
          {'id': 'x', 'qty': 0},
          {'qty': 1},
        ],
        'meta': {
          'tags': ['a', ''],
        },
        'ignored': true,
      };
      final validator = Validator(data, {
        'items': 'required|array|min:1',
        'items.*.id': 'required|integer',
        'items.*.qty': 'required|integer|min:1',
        'meta.tags.*': 'required|string',
      });
      final errors = await validator.run();
      expect(
        errors.keys,
        unorderedEquals([
          'items.1.id',
          'items.1.qty',
          'items.2.id',
          'meta.tags.1',
        ]),
      );
      expect(errors['items.2.id'], ['The items.2.id field is required.']);

      final validated = Validator(
        {
          'items': [
            {'id': 1, 'qty': 2, 'extra': 'no'},
          ],
          'meta': {
            'tags': ['a'],
            'other': 1,
          },
          'ignored': true,
        },
        {
          'items': 'array',
          'items.*.id': 'integer',
          'items.*.qty': 'integer',
          'meta.tags.*': 'string',
        },
      ).validated();
      expect(validated.toMap(), {
        'items': [
          {'id': 1, 'qty': 2, 'extra': 'no'},
        ],
        'meta': {
          'tags': ['a'],
        },
      });
    });

    test('ValidatedData typed accessors', () async {
      final data = await Validator(
        {
          'age': '42',
          'price': '9.5',
          'active': '1',
          'born': '2000-02-03',
          'tags': ['a'],
          'addr': {'city': 'Denpasar'},
        },
        {
          'age': 'integer',
          'price': 'numeric',
          'active': 'boolean',
          'born': 'date',
          'tags': 'array',
          'addr': 'map',
          'addr.city': 'string',
        },
      ).validate();
      expect(data.integer('age'), 42);
      expect(data.number('price'), 9.5);
      expect(data.boolean('active'), isTrue);
      expect(data.dateTime('born').year, 2000);
      expect(data.list<String>('tags'), ['a']);
      expect(data.nested('addr').string('city'), 'Denpasar');
      expect(data.maybeString('missing'), isNull);
      expect(() => data.string('missing'), throwsStateError);
      expect(data.only(['age']), {'age': '42'});
    });
  });

  group('messages, locales and DSL', () {
    test('custom messages, attribute names and Indonesian locale', () async {
      final en = await errorsOf(
        {'email': 'bad'},
        {'email': 'email', 'name': 'required'},
        messages: {
          'email.email': 'Please provide a real :attribute.',
          'required': ':attribute wajib.',
        },
        attributes: {'email': 'email address'},
      );
      expect(en['email'], ['Please provide a real email address.']);
      expect(en['name'], ['name wajib.']);

      final id = await errorsOf(
        {'nama_lengkap': ''},
        {'nama_lengkap': 'required'},
        locale: 'id',
      );
      expect(id['nama_lengkap'], ['Kolom nama lengkap wajib diisi.']);
    });

    test('DSL parsing is strict and supports regex with flags', () {
      expect(() => RuleParser.parse('required|nope'), throwsArgumentError);
      final rules = RuleParser.parse(
        r'required|regex:/^[a-z]+$/i|in:a,b|max:3',
      );
      expect(rules.map((r) => r.name), ['required', 'regex', 'in', 'max']);
      expect((rules[1] as RegexRule).pattern.hasMatch('ABC'), isTrue);
      expect(RuleParser.parseValue([Rules.required(), 'email']).length, 2);
    });

    test('ValidationException summarizes like Laravel 12', () {
      final one = ValidationException({
        'a': ['The a field is required.'],
      });
      expect(one.message, 'The a field is required.');
      final many = ValidationException.withMessages({
        'a': 'A bad',
        'b': ['B bad', 'B worse'],
      });
      expect(many.message, 'A bad (and 2 more errors)');
      expect(many.status, 422);
      expect(many.toJson()['errors'], {
        'a': ['A bad'],
        'b': ['B bad', 'B worse'],
      });
    });
  });

  group('integration with Request, FormRequest and the database', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r.post('/users', (req) async {
                final data = await req.validate({
                  'email': 'required|email|unique:users,email',
                  'name': 'required|string|max:5',
                });
                return Response.created(data.toMap());
              });
              r.post(
                '/form',
                (req) async =>
                    (await FormRequest.run(_StoreForm(), req)).toMap(),
              );
            },
          )
          .create();
      await app.boot();
      await app.run(() async {
        await DB.statement(
          'CREATE TABLE users ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "email" TEXT, "name" TEXT)',
        );
        await DB.statement(
          'INSERT INTO users ("email", "name") VALUES (?, ?)',
          ['taken@x.test', 'T'],
        );
      });
    });

    tearDown(() => app.shutdown());

    test(
      'request.validate renders 422 with Laravel JSON and unique hits the database',
      () async {
        final response = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/users',
            json: {'email': 'taken@x.test', 'name': 'toolong'},
          ),
        );
        expect(response.status, 422);
        expect(await response.bodyText(), contains('"errors"'));
        expect(
          await response.bodyText(),
          contains('The email has already been taken.'),
        );
        expect(await response.bodyText(), contains('(and 1 more error)'));

        final ok = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/users',
            json: {'email': 'new@x.test', 'name': 'Ana', 'extra': 1},
          ),
        );
        expect(ok.status, 201);
        expect(await ok.bodyText(), '{"email":"new@x.test","name":"Ana"}');
      },
    );

    test('FormRequest authorizes, prepares and validates', () async {
      final forbidden = await app.handle(
        Request.fake(method: 'POST', path: '/api/form', json: {'deny': true}),
      );
      expect(forbidden.status, 403);

      final invalid = await app.handle(
        Request.fake(method: 'POST', path: '/api/form', json: {'title': ''}),
      );
      expect(invalid.status, 422);
      expect(await invalid.bodyText(), contains('Judul wajib diisi.'));

      final ok = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/form',
          json: {'title': '  hello '},
        ),
      );
      expect(await ok.bodyText(), '{"title":"HELLO"}');
    });
  });
}

final class _StoreForm extends FormRequest {
  @override
  Future<bool> authorize(Request request) async =>
      await request.input<bool>('deny') != true;

  @override
  Map<String, Object> rules(Request request) => {
    'title': 'required|string|max:10',
  };

  @override
  Map<String, String> messages() => {'title.required': 'Judul wajib diisi.'};

  @override
  Map<String, Object?> prepare(Request request, Map<String, Object?> input) => {
    ...input,
    if (input['title'] case final String title) 'title': title.trim(),
  };

  @override
  ValidatedData passed(Request request, ValidatedData data) =>
      ValidatedData({'title': data.string('title').toUpperCase()});
}
