import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class StoreNoteRequest extends FormRequest<StoreNoteInput> {
  const StoreNoteRequest();

  static const title = Field<String>('title');
  static const stars = Field<int?>('stars');

  @override
  bool authorize(Request request) => false;

  @override
  Map<String, Object> rules(Request request) => {
    title: [Rules.required(), Rules.string(), Rules.max(20)],
    stars: [Rules.nullable(), Rules.integer()],
  };
}

extension type const StoreNoteInput(ValidatedData _data)
    implements ValidatedData {
  String get title => _data.field(StoreNoteRequest.title);
  int? get stars => _data.field(StoreNoteRequest.stars);

  Map<String, Object?> get typed => {'title': title, 'stars': stars};
}

/// `Field<int>` with rules that let any string through.
final class LooseRequest extends FormRequest<LooseInput> {
  const LooseRequest();

  static const pin = Field<int>('pin');

  @override
  Map<String, Object> rules(Request request) => {pin: 'required'};
}

extension type const LooseInput(ValidatedData _data) implements ValidatedData {
  int get pin => _data.field(LooseRequest.pin);

  Map<String, Object?> get typed => {'pin': pin};
}

Matcher failsWith(Matcher message) =>
    throwsA(isA<TestFailure>().having((e) => e.message, 'message', message));

void main() {
  test('a valid sample reads every field, converted', () async {
    // authorize() returns false: not run, this is about the input types.
    final input = await expectFormRequestTyped(const StoreNoteRequest(), {
      'title': 'Hello',
      'stars': '4',
    }, read: (input) => input.typed);
    expect(input.typed, {'title': 'Hello', 'stars': 4});
  });

  test('a field its rules do not type fails with the request and field', () {
    expect(
      expectFormRequestTyped(const LooseRequest(), {
        'pin': 's3cret-pin',
      }, read: (input) => input.typed),
      failsWith(
        allOf(
          contains('LooseRequest'),
          contains('[pin]'),
          contains('Field<int>'),
          isNot(contains('s3cret')),
        ),
      ),
    );
  });

  test('a sample that fails validation lists fields and rules only', () {
    expect(
      expectFormRequestTyped(const StoreNoteRequest(), {
        'title': 's3cret-but-far-too-long-title',
        'stars': 'x',
      }, read: (input) => input.typed),
      failsWith(
        allOf(
          contains('StoreNoteRequest'),
          contains('title: max'),
          contains('stars: integer'),
          isNot(contains('s3cret')),
        ),
      ),
    );
  });
}
