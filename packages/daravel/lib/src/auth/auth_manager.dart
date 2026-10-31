import 'dart:async';
import 'dart:convert';

import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../http/middleware.dart';
import '../http/request.dart';
import '../http/response.dart';
import 'authorization.dart';
import 'contracts.dart';
import 'encryption.dart';
import 'jwt.dart';
import 'tokens.dart';

/// `AUTH_*` / `JWT_*` configuration (`config/auth.php` parity).
final class AuthConfig implements ConfigSection {
  const AuthConfig({
    this.defaultGuard = 'token',
    this.tokenExpiration,
    this.tokenTable = 'personal_access_tokens',
    this.tokenPrefix = '',
    this.jwtSecret,
    this.jwtAlgorithm = .hs256,
    this.jwtTtl = const Duration(minutes: 60),
    this.jwtLeeway = const Duration(seconds: 30),
    this.jwtIssuer,
    this.jwtAudience,
    this.jwtPublicKey,
    this.jwtPrivateKey,
    this.jwtKid,
  });

  factory AuthConfig.fromEnv(Env env) => AuthConfig(
    defaultGuard: env.string('AUTH_GUARD', 'token'),
    tokenExpiration: env.has('AUTH_TOKEN_EXPIRATION')
        ? Duration(minutes: env.integer('AUTH_TOKEN_EXPIRATION'))
        : null,
    tokenTable: env.string('AUTH_TOKEN_TABLE', 'personal_access_tokens'),
    tokenPrefix: env.string('SANCTUM_TOKEN_PREFIX', ''),
    jwtSecret: env.maybeString('JWT_SECRET'),
    jwtAlgorithm: JwtAlgorithm.parse(env.string('JWT_ALGO', 'HS256')),
    jwtTtl: Duration(minutes: env.integer('JWT_TTL', 60)),
    jwtLeeway: Duration(seconds: env.integer('JWT_LEEWAY', 30)),
    jwtIssuer: env.maybeString('JWT_ISSUER'),
    jwtAudience: env.maybeString('JWT_AUDIENCE'),
    jwtPublicKey: env.maybeString('JWT_PUBLIC_KEY'),
    jwtPrivateKey: env.maybeString('JWT_PRIVATE_KEY'),
    jwtKid: env.maybeString('JWT_KID'),
  );

  final String defaultGuard;

  /// Sanctum-style global token lifetime (`AUTH_TOKEN_EXPIRATION` minutes).
  final Duration? tokenExpiration;
  final String tokenTable;

  /// Prefix for new token secrets (`SANCTUM_TOKEN_PREFIX`, as in Sanctum).
  final String tokenPrefix;

  /// HS256 secret; falls back to `APP_KEY` when unset.
  final String? jwtSecret;
  final JwtAlgorithm jwtAlgorithm;
  final Duration jwtTtl;
  final Duration jwtLeeway;
  final String? jwtIssuer;
  final String? jwtAudience;

  /// Base64 Ed25519 public key (EdDSA).
  final String? jwtPublicKey;

  /// Base64 Ed25519 32-byte seed (EdDSA signing).
  final String? jwtPrivateKey;
  final String? jwtKid;

  @override
  String get key => 'auth';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'defaults': {'guard': defaultGuard},
    'tokens': {
      'expiration': tokenExpiration?.inMinutes,
      'table': tokenTable,
      'prefix': tokenPrefix,
    },
    'jwt': {
      'algorithm': jwtAlgorithm.header,
      'ttl': jwtTtl.inMinutes,
      'leeway': jwtLeeway.inSeconds,
      'issuer': jwtIssuer,
      'audience': jwtAudience,
      'kid': jwtKid,
    },
  };
}

/// Multi-guard authentication manager (Laravel `AuthManager`).
///
/// Guards are registered at boot (`withAuth`); every query goes through the
/// guard named explicitly, the one activated by `auth:a,b` middleware for
/// this request, or the configured default.
final class AuthManager {
  AuthManager(this.config, {this._appKey, this.jwtDenylist});

  final AuthConfig config;
  final String? _appKey;

  /// The denylist of [jwt] guards that are not given one: shared by every
  /// isolate when the application builds it (`CacheJwtDenylist`).
  final JwtDenylist? jwtDenylist;
  final Map<String, Guard<Authenticatable>> _guards =
      <String, Guard<Authenticatable>>{};
  String? _defaultOverride;

  /// Default guard name (`AUTH_GUARD`, or [shouldUse]).
  String get defaultGuard => _defaultOverride ?? config.defaultGuard;

  Iterable<String> get guardNames => _guards.keys;

  bool hasGuard(String name) => _guards.containsKey(name);

  /// Registers a custom guard.
  void register(String name, Guard<Authenticatable> guard) =>
      _guards[name] = guard;

  /// Registers a Sanctum-style [TokenGuard].
  TokenGuard<T> token<T extends Authenticatable>(
    String name,
    UserProvider<T> provider, {
    Duration? expiration,
    String? table,
  }) {
    final guard = TokenGuard<T>(
      name: name,
      provider: provider,
      table: table ?? config.tokenTable,
      expiration: expiration ?? config.tokenExpiration,
      tokenPrefix: config.tokenPrefix,
    );
    register(name, guard);
    return guard;
  }

  /// Registers a [JwtGuard]; the codec defaults to the `JWT_*` settings
  /// (HS256 with `JWT_SECRET` or `APP_KEY`, or EdDSA with `JWT_PUBLIC_KEY`).
  JwtGuard<T> jwt<T extends Authenticatable>(
    String name,
    UserProvider<T> provider, {
    JwtCodec? codec,
    Duration? ttl,
    JwtDenylist? denylist,
  }) {
    final guard = JwtGuard<T>(
      name: name,
      provider: provider,
      codec: codec ?? defaultJwtCodec(),
      ttl: ttl ?? config.jwtTtl,
      denylist: denylist ?? jwtDenylist,
    );
    register(name, guard);
    return guard;
  }

  /// Registers a closure guard (`Auth::viaRequest`).
  ClosureGuard<T> viaRequest<T extends Authenticatable>(
    String name,
    FutureOr<T?> Function(Request request) resolver, {
    UserProvider<T>? provider,
  }) {
    final guard = ClosureGuard<T>(
      name: name,
      resolver: resolver,
      provider: provider,
    );
    register(name, guard);
    return guard;
  }

  /// Builds the codec described by [config].
  JwtCodec defaultJwtCodec() {
    final keys = <JwtKey>[];
    final publicKey = config.jwtPublicKey;
    if (config.jwtAlgorithm == .eddsa) {
      if (publicKey == null || publicKey.isEmpty) {
        throw const ConfigException(
          'JWT_ALGO=EdDSA requires JWT_PUBLIC_KEY (and JWT_PRIVATE_KEY to '
          'sign). Generate them with `dartisan jwt:keygen`.',
        );
      }
      final seed = config.jwtPrivateKey;
      keys.add(
        Ed25519JwtKey(
          publicKey: base64.decode(publicKey),
          seed: seed == null || seed.isEmpty ? null : base64.decode(seed),
          kid: config.jwtKid,
        ),
      );
    } else {
      final secret = config.jwtSecret ?? _appKey;
      if (secret == null || secret.isEmpty) {
        throw const ConfigException(
          'JWT guards need JWT_SECRET (or APP_KEY) to sign HS256 tokens.',
        );
      }
      final bytes = secret.startsWith('base64:')
          ? Encrypter.parseKey(secret)
          : utf8.encode(secret);
      if (bytes.length < 32) {
        throw ConfigException(
          'JWT_SECRET must be at least 32 bytes (256 bits) for HS256; '
          'got ${bytes.length}. Generate one with `dartisan key:generate`.',
        );
      }
      keys.add(HmacJwtKey(bytes, kid: config.jwtKid));
    }
    return JwtCodec(
      keys: keys,
      leeway: config.jwtLeeway,
      issuer: config.jwtIssuer,
      audience: config.jwtAudience,
    );
  }

  /// The guard called [name], or the request-active/default guard.
  Guard<Authenticatable> guard([String? name]) {
    final resolved = name ?? _activeGuard() ?? defaultGuard;
    final guard = _guards[resolved];
    if (guard == null) {
      throw StateError(
        'Auth guard [$resolved] is not defined. Register it with '
        "withAuth((auth) => auth.token('$resolved', provider)).",
      );
    }
    return guard;
  }

  /// Changes the process-wide default guard (boot time).
  void shouldUse(String name) => _defaultOverride = name;

  /// Makes [name] the default guard for the current request/scope only.
  void useForRequest(String name) => AuthScope.state().activeGuard = name;

  Future<T?> user<T extends Authenticatable>({String? guard}) async =>
      await this.guard(guard).user() as T?;

  Future<Object?> id({String? guard}) => this.guard(guard).id();

  Future<bool> check({String? guard}) => this.guard(guard).check();

  Future<bool> guest({String? guard}) => this.guard(guard).guest();

  void setUser(Authenticatable user, {String? guard}) =>
      this.guard(guard).setUser(user);

  void forgetUser({String? guard}) => this.guard(guard).forgetUser();

  /// Validates credentials without authenticating the request.
  Future<bool> validate(Map<String, Object?> credentials, {String? guard}) =>
      this.guard(guard).validate(credentials);

  /// Looks up and validates credentials; returns the user when they match.
  Future<T?> retrieveByCredentials<T extends Authenticatable>(
    Map<String, Object?> credentials, {
    String? guard,
  }) async {
    final provider = this.guard(guard).provider;
    if (provider == null) {
      throw StateError(
        'Guard [${guard ?? defaultGuard}] has no user provider.',
      );
    }
    final user = await provider.retrieveByCredentials(credentials);
    if (user == null) {
      await equalizeLoginTiming(credentials);
      return null;
    }
    if (!await provider.validateCredentials(user, credentials)) {
      return null;
    }
    await provider.rehashPasswordIfRequired(user, credentials);
    return user as T?;
  }

  /// Authenticates the current request only (no token/session).
  Future<bool> once(Map<String, Object?> credentials, {String? guard}) async {
    final user = await retrieveByCredentials<Authenticatable>(
      credentials,
      guard: guard,
    );
    if (user == null) {
      return false;
    }
    setUser(user, guard: guard);
    return true;
  }

  /// Authenticates the current request as the user with [id].
  Future<T?> onceUsingId<T extends Authenticatable>(
    Object id, {
    String? guard,
  }) async {
    final user = await this.guard(guard).provider?.retrieveById(id);
    if (user != null) {
      setUser(user, guard: guard);
    }
    return user as T?;
  }

  /// The token guard named [name], or the first registered one.
  TokenGuard<Authenticatable> tokenGuard([String? name]) =>
      _guardOfType<TokenGuard<Authenticatable>>(name, 'TokenGuard');

  /// The JWT guard named [name], or the first registered one.
  JwtGuard<Authenticatable> jwtGuard([String? name]) =>
      _guardOfType<JwtGuard<Authenticatable>>(name, 'JwtGuard');

  /// Issues a personal access token (`$user->createToken()`).
  Future<NewAccessToken> issueToken(
    Authenticatable user,
    String name, {
    List<String> abilities = const <String>['*'],
    DateTime? expiresAt,
    String? guard,
  }) =>
      tokenGuard(guard)
          .issue(user, name, abilities: abilities, expiresAt: expiresAt);

  /// Issues a JWT for [user].
  Future<String> issueJwt(
    Authenticatable user, {
    Duration? ttl,
    Map<String, Object?> claims = const <String, Object?>{},
    String? guard,
  }) => jwtGuard(guard).issue(user, ttl: ttl, claims: claims);

  G _guardOfType<G extends Guard<Authenticatable>>(String? name, String label) {
    if (name != null) {
      final guard = this.guard(name);
      if (guard is G) {
        return guard;
      }
      throw StateError('Auth guard [$name] is not a $label.');
    }
    final active = _activeGuard() ?? defaultGuard;
    final preferred = _guards[active];
    if (preferred is G) {
      return preferred;
    }
    for (final guard in _guards.values) {
      if (guard is G) {
        return guard;
      }
    }
    throw StateError('No $label is registered. Add one in withAuth().');
  }

  String? _activeGuard() {
    try {
      return AuthScope.state().activeGuard;
    } on StateError {
      return null;
    }
  }
}

/// `auth` / `auth:token,jwt` — tries each guard in order and activates the
/// first that authenticates; otherwise 401 `{"message":"Unauthenticated."}`.
final class AuthenticateMiddleware implements RunsBeforeBindings {
  const AuthenticateMiddleware([this.guards = const <String>[]]);

  final List<String> guards;

  @override
  Future<Response> handle(Request request, Next next) async {
    final auth = Container.current.make<AuthManager>();
    final names = guards.isEmpty ? <String>[auth.defaultGuard] : guards;
    for (final name in names) {
      if (await auth.guard(name).check()) {
        auth.useForRequest(name);
        return next(request);
      }
    }
    throw AuthenticationException(guards: names);
  }
}

/// Auth helpers on the request (`$request->user()`, `bearerToken()`).
extension RequestAuth on Request {
  /// The `Authorization: Bearer` value, if any.
  String? bearerToken() => bearerTokenOf(this);

  AuthManager get auth => Container.current.make<AuthManager>();

  AuthorizationGate get gate => Container.current.make<AuthorizationGate>();

  /// The authenticated user (via [guard] or the active/default guard).
  Future<T?> user<T extends Authenticatable>({String? guard}) =>
      auth.user<T>(guard: guard);

  /// Throws 403 unless the current user may perform [ability].
  Future<AuthResponse> authorize(
    String ability, [
    List<Object?> args = const <Object?>[],
  ]) => gate.authorize(ability, args);

  Future<bool> can(String ability, [List<Object?> args = const <Object?>[]]) =>
      gate.allows(ability, args);

  Future<bool> cannot(
    String ability, [
    List<Object?> args = const <Object?>[],
  ]) => gate.denies(ability, args);
}
