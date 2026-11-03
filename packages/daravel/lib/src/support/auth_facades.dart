import '../auth/auth_manager.dart';
import '../auth/authorization.dart';
import '../auth/contracts.dart';
import '../auth/encryption.dart';
import '../auth/hashing.dart';
import '../auth/jwt.dart';
import '../auth/tokens.dart';
import '../foundation/container.dart';

/// Password hashing (`Hash::make`, `Hash::check`).
abstract final class Hash {
  /// The hash manager of the current container.
  static HashManager get manager => Container.current.make<HashManager>();

  /// Hashes [plain] with the default driver (bcrypt), or [driver]:
  /// `await Hash.make(password)`.
  static Future<String> make(String plain, {HashDriver? driver}) =>
      manager.make(plain, driver: driver);

  /// Whether [plain] matches [hashed].
  static Future<bool> check(String plain, String hashed) =>
      manager.check(plain, hashed);

  /// Whether [hashed] was made with other settings than the current ones,
  /// so it should be hashed again after a successful login.
  static bool needsRehash(String hashed) => manager.needsRehash(hashed);

  /// The algorithm and options [hashed] was made with.
  static HashInfo info(String hashed) => manager.info(hashed);

  /// Whether [value] looks like a hash this application accepts.
  static bool isHashed(String value) => manager.isHashed(value);
}

/// Symmetric encryption keyed by `APP_KEY` (`Crypt::encryptString`).
abstract final class Crypt {
  /// The encrypter of the current container (`APP_KEY`).
  static Encrypter get encrypter => Container.current.make<Encrypter>();

  /// Encrypts [value], serialized as Laravel's `encrypt()` does.
  static Future<String> encrypt(Object? value) => encrypter.encrypt(value);

  /// Decrypts a payload of [encrypt]; throws when it was tampered with.
  static Future<T> decrypt<T>(String payload) => encrypter.decrypt<T>(payload);

  /// Encrypts a string without serializing it (`Crypt::encryptString`).
  static Future<String> encryptString(String value) =>
      encrypter.encryptString(value);

  /// Decrypts a payload of [encryptString].
  static Future<String> decryptString(String payload) =>
      encrypter.decryptString(payload);
}

/// Authentication (`Auth::user()`, `Auth::guard('jwt')`).
abstract final class Auth {
  /// The auth manager of the current container.
  static AuthManager get manager => Container.current.make<AuthManager>();

  /// The guard [name], or the default one.
  static Guard<Authenticatable> guard([String? name]) => manager.guard(name);

  /// The authenticated user, or null for a guest.
  static Future<T?> user<T extends Authenticatable>({String? guard}) =>
      manager.user<T>(guard: guard);

  /// The authenticated user's id, or null.
  static Future<Object?> id({String? guard}) => manager.id(guard: guard);

  /// Whether a user is authenticated.
  static Future<bool> check({String? guard}) => manager.check(guard: guard);

  /// Whether the request is a guest's.
  static Future<bool> guest({String? guard}) => manager.guest(guard: guard);

  /// Authenticates [user] for the rest of the request.
  static void setUser(Authenticatable user, {String? guard}) =>
      manager.setUser(user, guard: guard);

  /// Forgets the authenticated user for the rest of the request.
  static void forgetUser({String? guard}) => manager.forgetUser(guard: guard);

  /// Whether [credentials] (email and password) are valid, without logging
  /// in.
  static Future<bool> validate(
    Map<String, Object?> credentials, {
    String? guard,
  }) => manager.validate(credentials, guard: guard);

  /// The user matching [credentials] (the password checked against its
  /// hash), or null.
  static Future<T?> retrieveByCredentials<T extends Authenticatable>(
    Map<String, Object?> credentials, {
    String? guard,
  }) => manager.retrieveByCredentials<T>(credentials, guard: guard);

  /// Authenticates the user of [credentials] for this request only.
  static Future<bool> once(Map<String, Object?> credentials, {String? guard}) =>
      manager.once(credentials, guard: guard);

  /// Authenticates the user with [id] for this request only.
  static Future<T?> onceUsingId<T extends Authenticatable>(
    Object id, {
    String? guard,
  }) => manager.onceUsingId<T>(id, guard: guard);

  /// The token guard [name], to issue and revoke tokens.
  static TokenGuard<Authenticatable> tokenGuard([String? name]) =>
      manager.tokenGuard(name);

  /// The JWT guard [name].
  static JwtGuard<Authenticatable> jwtGuard([String? name]) =>
      manager.jwtGuard(name);

  /// Issues a personal access token for [user] (Sanctum's `createToken`);
  /// the plain text is only available on the result.
  static Future<NewAccessToken> issueToken(
    Authenticatable user,
    String name, {
    List<String> abilities = const <String>['*'],
    DateTime? expiresAt,
    String? guard,
  }) => manager.issueToken(
    user,
    name,
    abilities: abilities,
    expiresAt: expiresAt,
    guard: guard,
  );

  /// Issues a JWT for [user].
  static Future<String> issueJwt(
    Authenticatable user, {
    Duration? ttl,
    Map<String, Object?> claims = const <String, Object?>{},
    String? guard,
  }) => manager.issueJwt(user, ttl: ttl, claims: claims, guard: guard);
}

/// Authorization (`Gate::allows`, `Gate::authorize`).
abstract final class Gate {
  /// The gate of the current container.
  static AuthorizationGate get gate =>
      Container.current.make<AuthorizationGate>();

  /// Defines [ability]: `Gate.define('edit-post', (user, [post]) => ...)`.
  static void define(String ability, GateCallback callback) =>
      gate.define(ability, callback);

  /// Registers [policy] for its model type.
  static void policy<T extends Object>(Policy<T> policy) =>
      gate.policy<T>(policy);

  /// Runs [hook] before every check; a non-null result decides it.
  static void before(GateBeforeHook hook) => gate.before(hook);

  /// Runs [hook] after every check.
  static void after(GateAfterHook hook) => gate.after(hook);

  /// Whether [ability] is defined.
  static bool has(String ability) => gate.has(ability);

  /// The gate checking as [user] instead of the authenticated one.
  static AuthorizationGate forUser(Authenticatable? user) => gate.forUser(user);

  /// Whether the authenticated user may do [ability] with [args].
  static Future<bool> allows(String ability, [List<Object?> args = const []]) =>
      gate.allows(ability, args);

  /// Whether the authenticated user may not do [ability].
  static Future<bool> denies(String ability, [List<Object?> args = const []]) =>
      gate.denies(ability, args);

  /// Whether every one of the abilities is allowed.
  static Future<bool> check(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.check(abilities, args);

  /// Whether any of the abilities is allowed.
  static Future<bool> any(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.any(abilities, args);

  /// Whether none of the abilities is allowed.
  static Future<bool> none(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.none(abilities, args);

  /// Allows [ability] or throws a 403 with the policy's message.
  static Future<AuthResponse> authorize(
    String ability, [
    List<Object?> args = const [],
  ]) => gate.authorize(ability, args);

  /// The full answer for [ability]: allowed or denied, with a message and
  /// code.
  static Future<AuthResponse> inspect(
    String ability, [
    List<Object?> args = const [],
  ]) => gate.inspect(ability, args);
}
