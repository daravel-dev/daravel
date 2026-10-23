import 'dart:async';

import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../foundation/container.dart';
import '../http/http_exceptions.dart';
import '../http/request.dart';
import 'hashing.dart';

/// Something that can be authenticated (Laravel `Authenticatable`).
abstract interface class Authenticatable {
  /// Primary identifier (stored in tokens and sessions).
  Object get authIdentifier;

  /// Column name of [authIdentifier] (`id`).
  String get authIdentifierName;

  /// Hashed password, or `null` for password-less accounts.
  String? get authPassword;

  /// Column name of [authPassword] (`password`).
  String get authPasswordName;

  /// "Remember me" token (session guard, T2).
  String? get rememberToken;
}

/// Default [Authenticatable] implementation for models:
///
/// ```dart
/// final class User extends Model with AuthenticatableModel { ... }
/// ```
base mixin AuthenticatableModel on Model implements Authenticatable {
  @override
  Object get authIdentifier {
    final id = key;
    if (id == null) {
      throw StateError(
        'Model [$table] has no primary key value; save it before using it '
        'as an authenticated user.',
      );
    }
    return id;
  }

  @override
  String get authIdentifierName => modelDefinition.primaryKey;

  @override
  String? get authPassword => attributes[authPasswordName] as String?;

  @override
  String get authPasswordName => 'password';

  @override
  String? get rememberToken => attributes['remember_token'] as String?;
}

/// Loads users for guards (Laravel `UserProvider`).
abstract interface class UserProvider<T extends Authenticatable> {
  Future<T?> retrieveById(Object id);

  /// Looks a user up by every credential except password-like keys.
  Future<T?> retrieveByCredentials(Map<String, Object?> credentials);

  /// Verifies the password credential against the stored hash.
  Future<bool> validateCredentials(T user, Map<String, Object?> credentials);

  Future<T?> retrieveByToken(Object id, String token);

  Future<void> updateRememberToken(T user, String token);

  /// Rehashes the password when the configured driver/cost changed
  /// (Laravel 11 `rehashPasswordIfRequired`).
  Future<void> rehashPasswordIfRequired(
    T user,
    Map<String, Object?> credentials, {
    bool force = false,
  });

  /// Polymorphic class name stored in `personal_access_tokens.tokenable_type`
  /// (`App\Models\User` when coexisting with a Laravel database).
  String get morphClass;
}

/// [UserProvider] backed by an ORM model definition.
///
/// `T` must be the model class and implement [Authenticatable] (use the
/// [AuthenticatableModel] mixin).
final class ModelUserProvider<T extends Authenticatable>
    implements UserProvider<T> {
  ModelUserProvider(
    this.definition, {
    HashManager? hasher,
    String? morphClass,
    this.passwordKey = 'password',
  }) : _hasher = hasher,
       _morphClass = morphClass;

  final ModelDefinition<Model> definition;
  final HashManager? _hasher;
  final String? _morphClass;

  /// Credential key holding the plain password.
  final String passwordKey;

  HashManager get hasher => _hasher ?? Container.current.make<HashManager>();

  @override
  String get morphClass => _morphClass ?? T.toString();

  @override
  Future<T?> retrieveById(Object id) async =>
      await definition.query().find(id) as T?;

  @override
  Future<T?> retrieveByCredentials(Map<String, Object?> credentials) async {
    final query = definition.query();
    var constrained = false;
    for (final entry in credentials.entries) {
      if (entry.key.contains('password')) {
        continue;
      }
      final value = entry.value;
      if (value is List<Object?>) {
        query.whereIn(entry.key, value);
      } else {
        query.where(entry.key, value);
      }
      constrained = true;
    }
    if (!constrained) {
      return null;
    }
    return await query.first() as T?;
  }

  @override
  Future<bool> validateCredentials(
    T user,
    Map<String, Object?> credentials,
  ) async {
    final plain = credentials[passwordKey];
    final hashed = user.authPassword;
    if (plain is! String || hashed == null || hashed.isEmpty) {
      return false;
    }
    return hasher.check(plain, hashed);
  }

  @override
  Future<T?> retrieveByToken(Object id, String token) async {
    final user = await retrieveById(id);
    final stored = user?.rememberToken;
    if (user == null || stored == null || stored.isEmpty) {
      return null;
    }
    return constantTimeEquals(stored, token) ? user : null;
  }

  @override
  Future<void> updateRememberToken(T user, String token) async {
    final model = user as Model;
    model.forceFill(<String, Object?>{'remember_token': token});
    await model.save();
  }

  @override
  Future<void> rehashPasswordIfRequired(
    T user,
    Map<String, Object?> credentials, {
    bool force = false,
  }) async {
    final plain = credentials[passwordKey];
    final hashed = user.authPassword;
    if (plain is! String || hashed == null) {
      return;
    }
    if (!force && !hasher.needsRehash(hashed)) {
      return;
    }
    final model = user as Model;
    model.forceFill(<String, Object?>{
      user.authPasswordName: await hasher.make(plain),
    });
    await model.save();
  }
}

/// Resolves the user for a request (Laravel `Guard`).
abstract interface class Guard<T extends Authenticatable> {
  String get name;

  UserProvider<T>? get provider;

  /// The authenticated user, cached for the current request/scope.
  Future<T?> user();

  Future<Object?> id();

  Future<bool> check();

  Future<bool> guest();

  /// Validates credentials without logging the user in.
  Future<bool> validate(Map<String, Object?> credentials);

  /// Sets the user for the current request/scope (tests, `once`).
  void setUser(T user);

  /// Clears the cached user for the current request/scope.
  void forgetUser();
}

/// A guard that also persists login state (session guard, T2).
abstract interface class StatefulGuard<T extends Authenticatable>
    implements Guard<T> {
  Future<bool> attempt(
    Map<String, Object?> credentials, {
    bool remember = false,
  });

  Future<void> login(T user, {bool remember = false});

  Future<void> logout();
}

/// 401 — no authenticated user for the attempted guards.
final class AuthenticationException extends HttpException {
  const AuthenticationException({
    String message = 'Unauthenticated.',
    this.guards = const <String>[],
    this.redirectTo,
  }) : super(401, message);

  final List<String> guards;
  final String? redirectTo;
}

/// 403 — the user may not perform the ability (`Gate.authorize`).
final class AuthorizationException extends HttpException {
  const AuthorizationException([
    String message = 'This action is unauthorized.',
    this.code,
  ]) : super(403, message);

  /// Application-defined code from `AuthResponse.deny(message, code)`.
  final Object? code;
}

/// Per-scope authentication state: resolved users per guard, the active
/// guard chosen by `auth:a,b` middleware and the current access token.
final class AuthState {
  final Map<String, Authenticatable?> users = <String, Authenticatable?>{};
  final Set<String> resolved = <String>{};
  String? activeGuard;
  Object? token;
}

/// Base for guards that resolve the user from the current [Request]:
/// caches per scope, so every call within one request hits the database at
/// most once.
abstract base class RequestGuard<T extends Authenticatable>
    implements Guard<T> {
  RequestGuard({required this.name, this.provider});

  @override
  final String name;

  @override
  final UserProvider<T>? provider;

  /// Resolves the user for [request] (`null` when unauthenticated).
  Future<T?> resolveUser(Request request);

  @override
  Future<T?> user() async {
    final state = AuthScope.state();
    if (state.resolved.contains(name)) {
      return state.users[name] as T?;
    }
    final request = AuthScope.request();
    final user = request == null ? null : await resolveUser(request);
    state.users[name] = user;
    state.resolved.add(name);
    return user;
  }

  @override
  Future<Object?> id() async => (await user())?.authIdentifier;

  @override
  Future<bool> check() async => await user() != null;

  @override
  Future<bool> guest() async => await user() == null;

  @override
  Future<bool> validate(Map<String, Object?> credentials) async {
    final found = await provider?.retrieveByCredentials(credentials);
    if (found == null) {
      return false;
    }
    return provider!.validateCredentials(found, credentials);
  }

  @override
  void setUser(T user) {
    final state = AuthScope.state();
    state.users[name] = user;
    state.resolved.add(name);
  }

  @override
  void forgetUser() {
    final state = AuthScope.state();
    state.users.remove(name);
    state.resolved.remove(name);
    state.token = null;
  }
}

/// A guard driven by a closure (`Auth.viaRequest`).
final class ClosureGuard<T extends Authenticatable> extends RequestGuard<T> {
  ClosureGuard({required super.name, required this.resolver, super.provider});

  final FutureOr<T?> Function(Request request) resolver;

  @override
  Future<T?> resolveUser(Request request) async => resolver(request);
}

/// Access to the active request scope for guards.
abstract final class AuthScope {
  /// The current request, when running inside the HTTP kernel.
  static Request? request() => _scope()?.get<Request>();

  /// Auth state of the active scope (request, job, command, test).
  static AuthState state() {
    final scope = _scope();
    if (scope == null) {
      throw StateError(
        'Auth requires an active scope. Call it inside a request handler, '
        'or wrap test code in `app.run(() async { ... })`.',
      );
    }
    return scope.get<AuthState>() ??
        (scope..put<AuthState>(AuthState())).get<AuthState>()!;
  }

  static Scope? _scope() {
    try {
      return Container.current.currentScope;
    } on StateError {
      return null;
    }
  }
}
