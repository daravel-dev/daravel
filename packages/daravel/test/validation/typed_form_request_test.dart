import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A typed form request (W9.5): the fields as `Field` constants, the input
/// as an extension type over `ValidatedData`, `validateRequest` returning
/// it with no `wrap` override.
final class StoreMemberRequest extends FormRequest<StoreMemberInput> {
  const StoreMemberRequest();

  static const name = Field<String>('name');
  static const age = Field<int>('age');
  static const nickname = Field<String?>('nickname');
  static const admin = Field<bool>('admin');
  static const born = Field<DateTime>('born');

  @override
  Map<String, Object> rules(Request request) => {
    name: [Rules.required(), Rules.string()],
    age: [Rules.required(), Rules.integer()],
    nickname: [Rules.nullable(), Rules.string()],
    admin: [Rules.required(), Rules.boolean()],
    born: [Rules.required(), Rules.date()],
  };
}

/// As `dartisan request:sync` writes it.
extension type const StoreMemberInput(ValidatedData _data)
    implements ValidatedData {
  String get name => _data.field(StoreMemberRequest.name);
  int get age => _data.field(StoreMemberRequest.age);
  String? get nickname => _data.field(StoreMemberRequest.nickname);
  bool get admin => _data.field(StoreMemberRequest.admin);
  DateTime get born => _data.field(StoreMemberRequest.born);
}

/// An untyped request, as written before: still `FormRequest<ValidatedData>`.
final class LegacyRequest extends FormRequest {
  const LegacyRequest();

  @override
  Map<String, Object> rules(Request request) => {'name': 'required|string'};
}

/// A field whose type its rules do not guarantee.
final class LooseRequest extends FormRequest<ValidatedData> {
  const LooseRequest();

  static const age = Field<int>('age');

  @override
  Map<String, Object> rules(Request request) => {age: 'required'};
}

void main() {
  Request post(Map<String, Object?> json) =>
      Request.fake(method: 'POST', path: '/members', json: json);

  test('validateRequest returns the typed input, without a wrap', () async {
    final StoreMemberInput data = await const StoreMemberRequest()
        .validateRequest(
          post({
            'name': 'Ana',
            'age': '42',
            'admin': '1',
            'born': '2001-02-03',
          }),
        );
    expect(data.name, 'Ana');
    expect(data.age, 42);
    expect(data.nickname, isNull);
    expect(data.admin, isTrue);
    expect(data.born, data.dateTime('born'));
    expect((data.born.year, data.born.month, data.born.day), (2001, 2, 3));
    // Still a ValidatedData: the old accessors work.
    expect(data.string('name'), 'Ana');
    expect(data.toMap(), containsPair('age', '42'));
  });

  test('an invalid request is still a 422 ValidationException', () {
    expect(
      const StoreMemberRequest().validateRequest(post({'name': 'Ana'})),
      throwsA(isA<ValidationException>()),
    );
  });

  test('an untyped FormRequest works as before', () async {
    final FormRequest<ValidatedData> form = const LegacyRequest();
    final data = await form.validateRequest(post({'name': 'Ana'}));
    expect(data.string('name'), 'Ana');
    expect(
      (await FormRequest.run(
        const LegacyRequest(),
        post({'name': 'Bo'}),
      )).string('name'),
      'Bo',
    );
  });

  test(
    'a field its rules do not guarantee names field and types, never the value',
    () async {
      final data = await const LooseRequest().validateRequest(
        post({'age': 's3cret-token'}),
      );
      expect(
        () => data.field(LooseRequest.age),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('[age]'),
              contains('Field<int>'),
              contains('String of length 12'),
              // User input may be a secret and this error reaches the log.
              isNot(contains('s3cret')),
            ),
          ),
        ),
      );
    },
  );

  test('a missing value of a non-nullable field says how to fix it', () {
    const data = ValidatedData({});
    expect(
      () => data.field(const Field<String>('name')),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('[name]'), contains('Field<String?>')),
        ),
      ),
    );
    expect(data.field(const Field<String?>('name')), isNull);
  });

  test('field converts as the typed accessors do', () {
    const data = ValidatedData({
      'n': '1.5',
      'i': 3,
      'nested': {'city': 'Denpasar'},
    });
    expect(data.field(const Field<double>('n')), 1.5);
    expect(data.field(const Field<num>('i')), 3);
    expect(data.field(const Field<double>('i')), 3.0);
    expect(
      data.field(const Field<ValidatedData>('nested')).string('city'),
      'Denpasar',
    );
  });
}
