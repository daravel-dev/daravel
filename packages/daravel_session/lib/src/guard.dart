import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'session.dart';

/// Laravel's `SessionGuard`: the user id lives in the session under the same
/// `login_web_<sha1>` key, so a user logged in on either side of a shared
/// store is logged in on both.
///
/// Register it with `auth.session<User>('web', provider)` in `withAuth`, on
/// routes in the `web` group. "Remember me" cookies are not supported.
final class SessionGuard<T extends Authenticatable> extends RequestGuard<T>
    implements StatefulGuard<T> {
  SessionGuard({
    required super.name,
    required UserProvider<T> provider,
    this.hashKey,
  }) : super(provider: provider);

  /// `sha1('Illuminate\Auth\SessionGuard')`, the class name in Laravel's key.
  static const String _classHash = '59ba36addc2b2f9401580f014c7f58ea4e30989d';

  /// `APP_KEY`, the key of [hashPasswordForCookie].
  final String? hashKey;

  /// Laravel's `getName()`.
  String get sessionKey => 'login_${name}_$_classHash';

  /// The session key `AuthenticateSession` compares.
  String get passwordHashKey => 'password_hash_$name';

  Session get _session =>
      Session.current ??
      (throw StateError(
        'The session guard [$name] needs a session: put the route in the '
        '`web` group.',
      ));

  @override
  Future<T?> resolveUser(Request request) async {
    final id = Session.current?.get<Object>(sessionKey);
    return id == null ? null : provider!.retrieveById(id);
  }

  /// Logs in the user the [credentials] identify. Failed attempts take the
  /// same time for unknown and known accounts.
  @override
  Future<bool> attempt(
    Map<String, Object?> credentials, {
    bool remember = false,
  }) async {
    final provider = this.provider!;
    final user = await provider.retrieveByCredentials(credentials);
    if (user == null) {
      await equalizeLoginTiming(credentials);
      return false;
    }
    if (!await provider.validateCredentials(user, credentials)) {
      return false;
    }
    await provider.rehashPasswordIfRequired(user, credentials);
    await login(user, remember: remember);
    return true;
  }

  /// Stores [user] in the session and gives it a new id and CSRF token, so
  /// an id fixed before the login is worthless after it.
  @override
  Future<void> login(T user, {bool remember = false}) async {
    if (remember) {
      throw UnsupportedError(
        'SessionGuard does not support "remember me" cookies.',
      );
    }
    final session = _session..put(sessionKey, user.authIdentifier);
    await session.regenerate(destroy: true);
    // Laravel 12 added this entry; older versions keep none on login.
    if (currentLaravelCompat() >= 12) {
      final password = user.authPassword;
      if (password != null && password.isNotEmpty) {
        session.put(passwordHashKey, hashPasswordForCookie(password));
      }
    }
    setUser(user);
  }

  /// Forgets the user. Like Laravel's guard this keeps the session itself:
  /// call `session.invalidate()` too on a logout route.
  @override
  Future<void> logout() async {
    _session.forget(sessionKey);
    forgetUser();
  }

  /// Laravel's `hashPasswordForCookie`.
  String hashPasswordForCookie(String passwordHash) => Hmac(
    sha256,
    utf8.encode(hashKey ?? 'base-key-for-password-hash-mac'),
  ).convert(utf8.encode(passwordHash)).toString();
}

/// `auth.session<User>('web', provider)` in `withAuth`.
extension SessionAuthManager on AuthManager {
  /// Registers a [SessionGuard] called [name].
  SessionGuard<T> session<T extends Authenticatable>(
    String name,
    UserProvider<T> provider,
  ) {
    final guard = SessionGuard<T>(
      name: name,
      provider: provider,
      hashKey: appKey,
    );
    register(name, guard);
    return guard;
  }
}
