import 'package:daravel/daravel.dart';

/// Validates `POST /api/auth/login`.
final class LoginRequest extends FormRequest<LoginInput> {
  const LoginRequest();

  /// One `Field` per input; `dartisan request:sync` writes the typed
  /// getters of [LoginInput] from them.
  static const email = Field<String>('email');
  static const password = Field<String>('password');
  static const deviceName = Field<String?>('device_name');

  @override
  Map<String, Object> rules(Request request) => {
    email: Rules.required().email(),
    password: Rules.required().string(),
    deviceName: Rules.sometimes().string().max(100),
  };
}

// <dartisan:input>
/// The validated input of [LoginRequest], one getter per `Field`
/// (written by `dartisan request:sync`; edit the fields, not this).
extension type const LoginInput(ValidatedData _data) implements ValidatedData {
  String get email => _data.field(LoginRequest.email);
  String get password => _data.field(LoginRequest.password);
  String? get deviceName => _data.field(LoginRequest.deviceName);

  /// Every field by its input key, as its declared type: the values are
  /// converted (`'4'` is `4` for a `Field<int>`), unlike the raw map of
  /// [ValidatedData]. `expectFormRequestTyped` reads every field with it.
  Map<String, Object?> get typed => {
    'email': email,
    'password': password,
    'device_name': deviceName,
  };
}
// </dartisan:input>
