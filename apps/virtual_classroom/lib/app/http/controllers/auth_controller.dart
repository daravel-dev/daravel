import 'package:daravel/daravel.dart';

import '../../models/user.dart';

/// Handles authentication and demo token switching.
final class AuthController {
  const AuthController();

  /// `POST /api/auth/login`
  Future<Object?> login(Request request) async {
    final data = await request.validate({
      'email': 'required|email',
      'password': 'required|string',
    });

    final user = await Auth.retrieveByCredentials<User>({
      'email': data.string('email'),
      'password': data.string('password'),
    });

    if (user == null) {
      throw ValidationException.withMessages({
        'email': ['Email atau password tidak sesuai.'],
      });
    }

    final token = await Auth.issueToken(user, 'web');
    final isTeacher = await user.isTeacher;

    return {
      'token': token.plainTextToken,
      'token_type': 'Bearer',
      'user': {
        'id': user.id,
        'name': user.name,
        'email': user.email,
        'role': isTeacher ? 'teacher' : 'student',
      },
    };
  }

  /// `POST /api/auth/demo-switch` - 1-click token issuing for demo switcher.
  Future<Object?> demoSwitch(Request request) async {
    final data = await request.validate({'email': 'required|email'});

    final user = await User.query()
        .where('email', data.string('email'))
        .first();
    if (user == null) {
      abort(404, 'User demo tidak ditemukan.');
    }

    final token = await Auth.issueToken(user, 'demo');
    final isTeacher = await user.isTeacher;

    return {
      'token': token.plainTextToken,
      'token_type': 'Bearer',
      'user': {
        'id': user.id,
        'name': user.name,
        'email': user.email,
        'role': isTeacher ? 'teacher' : 'student',
      },
    };
  }

  /// `GET /api/auth/me`
  Future<Object?> me(Request request) async {
    final user = (await request.user<User>())!;
    final isTeacher = await user.isTeacher;

    return {
      'id': user.id,
      'name': user.name,
      'email': user.email,
      'role': isTeacher ? 'teacher' : 'student',
    };
  }
}
