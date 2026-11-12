import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/events/user_registered.dart';
import 'package:daravel_starter/app/http/requests/login_request.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/http/resources/user_resource.dart';
import 'package:daravel_starter/app/models/user.dart';

/// Token-based authentication (Sanctum-style personal access tokens).
final class AuthController {
  /// JSON Schema of the register and login responses, for `.returns(...)`
  /// (OpenAPI, `dartisan client:flutter`).
  static const Map<String, Object?> tokenSchema = {
    'title': 'AuthToken',
    'type': 'object',
    'required': ['user', 'token', 'token_type'],
    'properties': {
      'user': UserResource.schema,
      'token': {'type': 'string'},
      'token_type': {
        'type': 'string',
        'enum': ['Bearer'],
      },
    },
  };

  /// `POST /api/auth/register` — creates the user and issues a token.
  /// The route validates [StoreUserRequest] and hands over its input.
  Future<Object?> register(Request request, StoreUserInput data) async {
    // Hash before the transaction so the expensive work holds no locks.
    final password = await Hash.make(data.password);
    // The user and its first token commit together, or not at all.
    final (user, token) = await DB.transaction(() async {
      final user = await User.createWith(
        name: data.name,
        email: data.email,
        password: password,
      );
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
  /// The route validates [LoginRequest] and hands over its input.
  Future<Object?> login(Request request, LoginInput data) async {
    final user = await Auth.retrieveByCredentials<User>({
      LoginRequest.email: data.email,
      LoginRequest.password: data.password,
    });
    if (user == null) {
      throw ValidationException.withMessages({
        LoginRequest.email: ['These credentials do not match our records.'],
      });
    }
    final token = await Auth.issueToken(user, data.deviceName ?? 'api');
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
