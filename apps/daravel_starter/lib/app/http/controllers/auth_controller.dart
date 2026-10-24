import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/events/user_registered.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/http/resources/user_resource.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Token-based authentication (Sanctum-style personal access tokens).
final class AuthController {
  /// `POST /api/auth/register` — creates the user and issues a token.
  Future<Object?> register(Request request) async {
    final data = await FormRequest.run(const StoreUserRequest(), request);
    // Hash before the transaction so the expensive work holds no locks.
    final password = await Hash.make(data.string('password'));
    // The user and its first token commit together, or not at all.
    final (user, token) = await DB.transaction(() async {
      final user = await User.create({
        'name': data.string('name'),
        'email': data.string('email'),
        'password': password,
      });
      return (user, await Auth.issueToken(user, 'api'));
    });
    await Event.dispatch(UserRegistered(user.id, user.email));
    return Response.created(<String, Object?>{
      'user': UserResource(user),
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
      'user': UserResource(user),
      'token': token.plainTextToken,
      'token_type': 'Bearer',
    };
  }

  /// `GET /api/auth/me` — the authenticated user.
  Future<Object?> me(Request request) async =>
      UserResource((await request.user<User>())!);

  /// `POST /api/auth/logout` — revokes the current token.
  Future<Object?> logout(Request request) async {
    await Auth.tokenGuard().revokeCurrent();
    return Response.noContent();
  }
}
