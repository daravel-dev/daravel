import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Validates [input] with [form], then reads every typed field through
/// [read], and fails the test when a field's declared type and its rules
/// disagree: a `Field<int>` whose rules let a string through, or a
/// `Field<String>` without `required`. Such a request passes validation
/// and then throws in the handler (a 500), so the mismatch is caught here
/// instead of in production.
///
/// ```dart
/// test('StoreNoteRequest reads every field as its type', () async {
///   await expectFormRequestTyped(
///     const StoreNoteRequest(),
///     {'title': 'Hello', 'stars': '4'},
///     read: (input) => input.typed,
///   );
/// });
/// ```
///
/// `typed` is the map `dartisan request:sync` writes into the input type;
/// an input type written by hand passes its own `read`. An extension type
/// member cannot be called through the type parameter [D], which is why
/// the caller, who knows the input type, supplies [read].
///
/// The test is as strong as its [input]: one valid input reads the fields
/// it holds. Add one call per branch of an optional rule (a `nullable`
/// field present and absent, a `sometimes` field sent and not).
///
/// [FormRequest.authorize] is not run (this checks the input types, not
/// who may send them); `prepare` and `passed` are. A failure names the
/// request class and, for a validation failure, each field with the rules
/// that failed, never the input values (they may be secrets).
Future<D> expectFormRequestTyped<D extends ValidatedData>(
  FormRequest<D> form,
  Map<String, Object?> input, {
  required Map<String, Object?> Function(D input) read,
}) async {
  final request = Request.fake(method: 'POST', path: '/', json: input);
  final validator = Validator(
    await form.prepare(request, await request.all()),
    form.rules(request),
    messages: form.messages(),
    attributes: form.attributes(),
    container: _containerOrNull(),
  );
  await validator.run();
  final failed = validator.failed();
  if (validator.errors.isNotEmpty) {
    final lines = [
      for (final field in validator.errors.keys)
        '  $field: ${failed[field]?.join(', ') ?? 'an after hook'}',
    ];
    fail(
      '${form.runtimeType}: the sample input does not pass its rules; '
      'fix the sample:\n${lines.join('\n')}',
    );
  }
  final data = await form.passed(request, validator.validated()) as D;
  try {
    read(data);
  } on StateError catch (e) {
    fail('${form.runtimeType}: ${e.message}');
  }
  return data;
}

Container? _containerOrNull() {
  try {
    return Container.current;
  } on StateError {
    return null;
  }
}
