import 'package:daravel/daravel.dart';

/// Validates `PATCH /api/users/{id}`. The handler validates it after the
/// policy check (`validateRequest`), so a stranger gets 403, not 422.
final class UpdateUserRequest extends FormRequest<UpdateUserInput> {
  const UpdateUserRequest();

  /// One `Field` per input; `dartisan request:sync` writes the typed
  /// getters of [UpdateUserInput] from them.
  static const name = Field<String>('name');

  @override
  Map<String, Object> rules(Request request) => {
    name: Rules.required().string().min(2).max(100),
  };
}

// <dartisan:input>
/// The validated input of [UpdateUserRequest], one getter per `Field`
/// (written by `dartisan request:sync`; edit the fields, not this).
extension type const UpdateUserInput(ValidatedData _data)
    implements ValidatedData {
  String get name => _data.field(UpdateUserRequest.name);

  /// Every field by its input key, as its declared type: the values are
  /// converted (`'4'` is `4` for a `Field<int>`), unlike the raw map of
  /// [ValidatedData]. `expectFormRequestTyped` reads every field with it.
  Map<String, Object?> get typed => {'name': name};
}
// </dartisan:input>
