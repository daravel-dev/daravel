import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Validates `POST /api/users` and `POST /api/auth/register`.
final class StoreUserRequest extends FormRequest<StoreUserInput> {
  const StoreUserRequest();

  /// One `Field` per input; `dartisan request:sync` writes the typed
  /// getters of [StoreUserInput] from them.
  static const name = Field<String>('name');
  static const email = Field<String>('email');
  static const password = Field<String>('password');

  @override
  Map<String, Object> rules(Request request) => {
    name: Rules.required().string().min(2).max(100),
    email: [
      Rules.required().email().max(255),
      Rules.of(User.definition).unique(User.cols.email),
    ],
    password: [Rules.required(), Rules.password(min: 8), Rules.confirmed()],
  };

  @override
  Map<String, String> attributes() => {email: 'email address'};
}

// <dartisan:input>
/// The validated input of [StoreUserRequest], one getter per `Field`
/// (written by `dartisan request:sync`; edit the fields, not this).
extension type const StoreUserInput(ValidatedData _data)
    implements ValidatedData {
  String get name => _data.field(StoreUserRequest.name);
  String get email => _data.field(StoreUserRequest.email);
  String get password => _data.field(StoreUserRequest.password);

  /// Every field by its input key, as its declared type: the values are
  /// converted (`'4'` is `4` for a `Field<int>`), unlike the raw map of
  /// [ValidatedData]. `expectFormRequestTyped` reads every field with it.
  Map<String, Object?> get typed => {
    'name': name,
    'email': email,
    'password': password,
  };
}
// </dartisan:input>
