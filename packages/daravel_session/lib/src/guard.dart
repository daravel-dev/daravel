import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'session.dart';

/// Laravel's `SessionGuard`: the user id lives in the session under the same
/// `login_web_<sha1>` key, so a user logged in on either side of a shared
/// store is logged in on both.
///
/// Register it with `auth.session<User>('web', provider)` in `withAuth`, on
/// routes in the `web` group. "Remember me" uses Laravel's
/// `remember_web_<sha1>` cookie, the `remember_token` column and the third
/// segment each version writes, and needs `EncryptCookiesMiddleware`.
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

  /// Laravel's `getRecallerName()`.
  String get recallerName => 'remember_${name}_$_classHash';

  /// `SessionGuard::$rememberDuration`: five years.
  static const Duration rememberDuration = Duration(minutes: 2628000);

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
    final session = Session.current;
    if (session == null) {
      return null;
    }
    final id = session.get<Object>(sessionKey);
    final user = id == null ? null : await provider!.retrieveById(id);
    if (user != null) {
      return user;
    }
    final remembered = await _userFromRecaller(request);
    if (remembered != null) {
      await _updateSession(session, remembered);
    }
    return remembered;
  }

  /// `userFromRecaller`: `id|token|hash`. From Laravel 12 the hash must
  /// be the password's HMAC, or the bare hash older versions wrote.
  Future<T?> _userFromRecaller(Request request) async {
    final segments = request.cookie(recallerName)?.split('|');
    if (segments == null ||
        segments.length < 3 ||
        segments[0].trim().isEmpty ||
        segments[1].trim().isEmpty) {
      return null;
    }
    final Object id = int.tryParse(segments[0]) ?? segments[0];
    final user = await provider!.retrieveByToken(id, segments[1]);
    if (user == null || currentLaravelCompat() < 12) {
      return user;
    }
    final password = user.authPassword;
    if (password == null) {
      return null;
    }
    return constantTimeEquals(hashPasswordForCookie(password), segments[2]) ||
            constantTimeEquals(password, segments[2])
        ? user
        : null;
  }

  Future<void> _updateSession(Session session, T user) async {
    session.put(sessionKey, user.authIdentifier);
    await session.regenerate(destroy: true);
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
    final session = _session;
    await _updateSession(session, user);
    // Laravel 12 added this entry; older versions keep none on login.
    if (currentLaravelCompat() >= 12) {
      final password = user.authPassword;
      if (password != null && password.isNotEmpty) {
        session.put(passwordHashKey, hashPasswordForCookie(password));
      }
    }
    if (remember) {
      await _queueRecaller(session, user);
    }
    setUser(user);
  }

  Future<void> _queueRecaller(Session session, T user) async {
    var token = user.rememberToken;
    if (token == null || token.isEmpty) {
      token = await _cycleRememberToken(user);
    }
    final password = user.authPassword ?? '';
    final hash = currentLaravelCompat() >= 12
        ? hashPasswordForCookie(password)
        : password;
    session.queuedCookies[recallerName] = (
      '${user.authIdentifier}|$token|$hash',
      rememberDuration,
    );
  }

  Future<String> _cycleRememberToken(T user) async {
    final token = Str.random(60);
    await provider!.updateRememberToken(user, token);
    return token;
  }

  /// Forgets the user. Like Laravel's guard this keeps the session itself:
  /// call `session.invalidate()` too on a logout route.
  @override
  Future<void> logout() async {
    final session = _session;
    final current = await user();
    session.forget(sessionKey);
    if (AuthScope.request()?.cookie(recallerName) != null) {
      session.queuedCookies[recallerName] = (null, null);
    }
    final token = current?.rememberToken;
    if (current != null && token != null && token.isNotEmpty) {
      await _cycleRememberToken(current);
    }
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
