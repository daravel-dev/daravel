import 'dart:async';

import '../foundation/container.dart';
import '../foundation/locale.dart';
import '../http/http_exceptions.dart';
import '../http/request.dart';
import 'validated_data.dart';
import 'validator.dart';

/// Reusable authorization + validation for a request (Laravel `FormRequest`).
///
/// ```dart
/// final class StoreUserRequest extends FormRequest {
///   @override
///   Map<String, Object> rules(Request request) => {
///     'email': 'required|email|unique:users',
///     'password': [Rules.required(), Rules.password(min: 8), Rules.confirmed()],
///   };
/// }
///
/// final data = await FormRequest.run(StoreUserRequest(), request);
/// ```
///
/// Typed (wave 9): declare the fields once as [Field] constants and give
/// the request its input type [D], an extension type over [ValidatedData]
/// with one getter per field (`dartisan request:sync` writes it):
///
/// ```dart
/// final class StoreUserRequest extends FormRequest<StoreUserInput> {
///   static const email = Field<String>('email');
///
///   @override
///   Map<String, Object> rules(Request request) => {
///     email: [Rules.required(), Rules.email()],
///   };
/// }
///
/// extension type const StoreUserInput(ValidatedData _data)
///     implements ValidatedData {
///   String get email => _data.field(StoreUserRequest.email);
/// }
///
/// final StoreUserInput data = await StoreUserRequest().validateRequest(request);
/// ```
///
/// `extends FormRequest` without a type argument is `FormRequest<ValidatedData>`,
/// as before.
abstract class FormRequest<D extends ValidatedData> {
  /// Form requests are usually const.
  const FormRequest();

  /// Runs this request against [request] as [run] does, and returns the
  /// validated input as [D]. No conversion is needed: an input type is an
  /// extension type over [ValidatedData], the same object at run time.
  Future<D> validateRequest(Request request) async =>
      await run(this, request) as D;

  /// Whether the current user may perform this request (`false` → 403).
  FutureOr<bool> authorize(Request request) => true;

  /// Rules keyed by attribute; values are DSL strings or `List<Rule>`.
  Map<String, Object> rules(Request request);

  /// Custom messages keyed by `attribute.rule` or `rule`.
  Map<String, String> messages() => const {};

  /// Display names for attributes.
  Map<String, String> attributes() => const {};

  /// Hook to massage the input before validation (`prepareForValidation`).
  FutureOr<Map<String, Object?>> prepare(
    Request request,
    Map<String, Object?> input,
  ) => input;

  /// Hook to post-process validated data (`passedValidation`).
  FutureOr<ValidatedData> passed(Request request, ValidatedData data) => data;

  /// Message for a failed [authorize].
  String get forbiddenMessage => 'This action is unauthorized.';

  /// Runs [form] against [request]: authorize (403) → validate (422).
  static Future<ValidatedData> run<T extends FormRequest>(
    T form,
    Request request,
  ) async {
    if (!await form.authorize(request)) {
      throw ForbiddenHttpException(form.forbiddenMessage);
    }
    final input = await form.prepare(request, await request.all());
    final validator = Validator(
      input,
      form.rules(request),
      messages: form.messages(),
      attributes: form.attributes(),
      container: _containerOrNull(),
      locale: request.attributes['locale'] as String? ?? currentLocale(),
    );
    return form.passed(request, await validator.validate());
  }

  static Container? _containerOrNull() {
    try {
      return Container.current;
    } on StateError {
      return null;
    }
  }
}
