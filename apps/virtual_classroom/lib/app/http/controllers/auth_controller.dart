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
        'email': [trans('auth.failed')],
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

  /// `POST /api/auth/demo-switch`: a token for a seeded user, without a
  /// password, for the page's account switcher. Local and testing only.
  Future<Object?> demoSwitch(Request request) async {
    ensureDemoMode();
    final data = await request.validate({'email': 'required|email'});

    final user = await User.query()
        .where('email', data.string('email'))
        .first();
    if (user == null) {
      abort(404);
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

/// The demo endpoints (`demo-switch`, `demo/state`, `activity-logs`) hand
/// out tokens without a password and list every user: they answer only
/// while `APP_ENV` is `local` or `testing`, and 404 anywhere else.
void ensureDemoMode() {
  final app = Config.section<AppConfig>();
  if (!app.isLocal && !app.isTesting) {
    abort(404);
  }
}
