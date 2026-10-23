import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/events/user_registered.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Token-based authentication (Sanctum-style personal access tokens).
final class AuthController {
  /// `POST /api/auth/register` — creates the user and issues a token.
  Future<Object?> register(Request request) async {
    final data = await FormRequest.run(const StoreUserRequest(), request);
    final user = await User.create({
      'name': data.string('name'),
      'email': data.string('email'),
      'password': await Hash.make(data.string('password')),
    });
    await Event.dispatch(UserRegistered(user.id, user.email));
    final token = await Auth.issueToken(user, 'api');
    return Response.created(<String, Object?>{
      'user': user,
      'token': token.plainTextToken,
      'token_type': 'Bearer',
    });
  }

  /// `POST /api/auth/login` — validates credentials and issues a token.
  /// Throttled by the `login` limiter (5 attempts per minute per email+IP).
  Future<Object?> login(Request request) async {
    final data = await request.validate({
      'email': 'required|email',
      'password': 'required|string',
      'device_name': 'sometimes|string|max:100',
    });
    final user = await Auth.retrieveByCredentials<User>({
      'email': data.string('email'),
      'password': data.string('password'),
    });
    if (user == null) {
      throw ValidationException.withMessages({
        'email': ['These credentials do not match our records.'],
      });
    }
    final token = await Auth.issueToken(
      user,
      data.has('device_name') ? data.string('device_name') : 'api',
    );
    return <String, Object?>{
      'user': user,
      'token': token.plainTextToken,
      'token_type': 'Bearer',
    };
  }

  /// `GET /api/auth/me` — the authenticated user.
  Future<Object?> me(Request request) async => <String, Object?>{
    'data': await request.user<User>(),
  };

  /// `POST /api/auth/logout` — revokes the current token.
  Future<Object?> logout(Request request) async {
    await Auth.tokenGuard().revokeCurrent();
    return Response.noContent();
  }
}
