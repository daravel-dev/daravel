import 'package:daravel/daravel.dart';

/// Validates `POST /api/auth/login`.
final class LoginRequest extends FormRequest {
  const LoginRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'email': 'required|email',
    'password': 'required|string',
    'device_name': 'sometimes|string|max:100',
  };
}
