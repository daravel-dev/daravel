import 'package:daravel/daravel.dart';

import 'config.dart';
import 'manager.dart';
import 'middleware.dart';
import 'session.dart';

/// Never flashed (`$dontFlash` of Laravel's exception handler).
const Set<String> _dontFlash = {
  'current_password',
  'password',
  'password_confirmation',
};

/// `Handler::invalid()`: a browser or an Inertia visit goes back with the
/// errors and its input flashed. Clients expecting JSON, and requests
/// without a session, fall through to the 422.
///
/// The errors are JSON, not Laravel's `ViewErrorBag` object: a page of
/// a Laravel application reading this session does not see them.
Future<Response?> redirectInvalidRequest(
  ValidationException error,
  Request request,
) async {
  final session = Session.current;
  if (session == null || request.expectsJson) {
    return null;
  }
  final input = await request.all();
  session
    ..flash('errors', {'default': error.errors})
    ..flash('_old_input', {
      for (final MapEntry(:key, :value) in input.entries)
        if (!_dontFlash.contains(key) && value is! UploadedFile) key: value,
    });
  return Response.back(request, previous: session.previousUrl);
}

/// `withSession()` on the application builder.
extension SessionApplicationBuilder on ApplicationBuilder {
  /// Adds Laravel-compatible sessions (`SESSION_*` settings):
  ///
  /// - the [SessionManager] with the `file`, `database` and `array`
  ///   drivers;
  /// - the `encrypt_cookies`, `session` and `csrf` middleware aliases, and
  ///   the `web` group that runs the three in Laravel's order;
  /// - `request.session` and `Session.current` inside those routes.
  ///
  /// Put the `web` group on the routes that need a session:
  /// `router.group((r) {...}, middleware: ['web'])`. With the `database`
  /// driver, add [CreateSessionsTable] to the migrations.
  ApplicationBuilder withSession({
    List<String> csrfExcept = const <String>[],
    List<String> cookiesExcept = const <String>[],
  }) => withConfig<SessionConfig>(SessionConfig.fromEnv)
      .withConfigCheck(SessionConfig.check)
      .withBindings((container) {
        container.singleton<SessionManager>(
          (c) => SessionManager(
            c.make<ConfigRepository>().section<SessionConfig>(),
            basePath: c.make<Application>().basePath,
          ),
        );
        container.make<ExceptionHandler>().render<ValidationException>(
          redirectInvalidRequest,
        );
      })
      .withMiddleware(
        (middleware) => middleware
          ..alias(
            'encrypt_cookies',
            EncryptCookiesMiddleware(except: cookiesExcept),
          )
          ..alias('session', const StartSessionMiddleware())
          ..alias('csrf', VerifyCsrfTokenMiddleware(except: csrfExcept))
          ..group('web', const <Object>['encrypt_cookies', 'session', 'csrf']),
      );
}
