import 'package:daravel/daravel.dart';

/// Validates `POST /api/users`.
final class StoreUserRequest extends FormRequest {
  const StoreUserRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'name': 'required|string|min:2|max:100',
    'email': 'required|email|max:255|unique:users,email',
    'password': [Rules.required(), Rules.password(min: 8), Rules.confirmed()],
  };

  @override
  Map<String, String> attributes() => {'email': 'email address'};
}
