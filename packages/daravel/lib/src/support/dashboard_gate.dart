import 'dart:async';

import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/exceptions.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../logging/logger.dart';
import 'auth_facades.dart';

/// Who may open a dashboard (Horizon, Pulse, Reverb, the log viewer), one
/// rule for all of them, as Laravel Horizon's `Authenticate` and Laravel
/// Pulse's `Authorize` middleware decide:
///
/// - `APP_ENV=local`: yes;
/// - otherwise the package's callback, when one is set (Horizon's
///   `Horizon::auth`; for the others a Daravel addition for applications
///   without sessions);
/// - otherwise the gate (`viewHorizon`, `viewPulse`, ...) when it is
///   defined;
/// - otherwise no. `APP_ENV=testing` is no exception.
///
/// Middleware is never taken as authorization.
abstract final class DashboardGate {
  /// Whether [request] may open the dashboard that [ability] guards; a
  /// [callback] decides before the gate. A callback or gate that throws is
  /// a no, logged with [name] (`Horizon dashboard authorization failed`).
  /// Never throws: a configuration or logger that cannot be resolved is a
  /// no too.
  static Future<bool> allows(
    Request request, {
    required String ability,
    required String name,
    FutureOr<bool> Function(Request request)? callback,
  }) async {
    try {
      final app = Container.current
          .make<ConfigRepository>()
          .section<AppConfig>();
      if (app.isLocal) {
        return true;
      }
      if (callback != null) {
        return await callback(request);
      }
      return Gate.has(ability) && await Gate.allows(ability);
    } on Object catch (e, stack) {
      try {
        Container.current.make<Logger>().error(
          '$name authorization failed; the request is denied.',
          error: e,
          stackTrace: stack,
        );
      } on Object {
        // No logger to tell: the answer is still no.
      }
      return false;
    }
  }

  /// The middleware a dashboard sits behind: [given] when the application
  /// registers every entry in it, else a [ConfigException] naming
  /// `withSession()` and [authHint]; without [given], the `web` group when
  /// the application registers it (the session and its user), else none.
  /// [setup] names the call that took [given] (`withHorizon`).
  static List<Object> middleware(
    MiddlewareRegistry registry,
    List<Object>? given, {
    required String setup,
    required String authHint,
  }) {
    if (given == null) {
      // The gate decides either way: no session only means no user.
      return registry.groups.contains('web') ? const ['web'] : const [];
    }
    try {
      registry.resolveAll(given);
    } on StateError catch (e) {
      throw ConfigException(
        '$setup(middleware: $given) names middleware this application does '
        'not register (${e.message}). The web group comes with '
        'withSession() (daravel_session); without sessions, leave '
        'middleware out and authorize with $authHint((request) => ...).',
      );
    }
    return given;
  }
}
