import 'package:daravel/daravel.dart';

import 'config.dart';
import 'manager.dart';
import 'middleware.dart';

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
      .withBindings(
        (container) => container.singleton<SessionManager>(
          (c) => SessionManager(
            c.make<ConfigRepository>().section<SessionConfig>(),
            basePath: c.make<Application>().basePath,
          ),
        ),
      )
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
