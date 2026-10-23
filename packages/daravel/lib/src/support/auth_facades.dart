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
  static HashManager get manager => Container.current.make<HashManager>();

  static Future<String> make(String plain, {HashDriver? driver}) =>
      manager.make(plain, driver: driver);

  static Future<bool> check(String plain, String hashed) =>
      manager.check(plain, hashed);

  static bool needsRehash(String hashed) => manager.needsRehash(hashed);

  static HashInfo info(String hashed) => manager.info(hashed);

  static bool isHashed(String value) => manager.isHashed(value);
}

/// Symmetric encryption keyed by `APP_KEY` (`Crypt::encryptString`).
abstract final class Crypt {
  static Encrypter get encrypter => Container.current.make<Encrypter>();

  static Future<String> encrypt(Object? value) => encrypter.encrypt(value);

  static Future<T> decrypt<T>(String payload) => encrypter.decrypt<T>(payload);

  static Future<String> encryptString(String value) =>
      encrypter.encryptString(value);

  static Future<String> decryptString(String payload) =>
      encrypter.decryptString(payload);
}

/// Authentication (`Auth::user()`, `Auth::guard('jwt')`).
abstract final class Auth {
  static AuthManager get manager => Container.current.make<AuthManager>();

  static Guard<Authenticatable> guard([String? name]) => manager.guard(name);

  static Future<T?> user<T extends Authenticatable>({String? guard}) =>
      manager.user<T>(guard: guard);

  static Future<Object?> id({String? guard}) => manager.id(guard: guard);

  static Future<bool> check({String? guard}) => manager.check(guard: guard);

  static Future<bool> guest({String? guard}) => manager.guest(guard: guard);

  static void setUser(Authenticatable user, {String? guard}) =>
      manager.setUser(user, guard: guard);

  static void forgetUser({String? guard}) => manager.forgetUser(guard: guard);

  static Future<bool> validate(
    Map<String, Object?> credentials, {
    String? guard,
  }) => manager.validate(credentials, guard: guard);

  static Future<T?> retrieveByCredentials<T extends Authenticatable>(
    Map<String, Object?> credentials, {
    String? guard,
  }) => manager.retrieveByCredentials<T>(credentials, guard: guard);

  static Future<bool> once(Map<String, Object?> credentials, {String? guard}) =>
      manager.once(credentials, guard: guard);

  static Future<T?> onceUsingId<T extends Authenticatable>(
    Object id, {
    String? guard,
  }) => manager.onceUsingId<T>(id, guard: guard);

  static TokenGuard<Authenticatable> tokenGuard([String? name]) =>
      manager.tokenGuard(name);

  static JwtGuard<Authenticatable> jwtGuard([String? name]) =>
      manager.jwtGuard(name);

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

  static Future<String> issueJwt(
    Authenticatable user, {
    Duration? ttl,
    Map<String, Object?> claims = const <String, Object?>{},
    String? guard,
  }) => manager.issueJwt(user, ttl: ttl, claims: claims, guard: guard);
}

/// Authorization (`Gate::allows`, `Gate::authorize`).
abstract final class Gate {
  static AuthorizationGate get gate =>
      Container.current.make<AuthorizationGate>();

  static void define(String ability, GateCallback callback) =>
      gate.define(ability, callback);

  static void policy<T extends Object>(Policy<T> policy) =>
      gate.policy<T>(policy);

  static void before(GateBeforeHook hook) => gate.before(hook);

  static void after(GateAfterHook hook) => gate.after(hook);

  static bool has(String ability) => gate.has(ability);

  static AuthorizationGate forUser(Authenticatable? user) => gate.forUser(user);

  static Future<bool> allows(String ability, [List<Object?> args = const []]) =>
      gate.allows(ability, args);

  static Future<bool> denies(String ability, [List<Object?> args = const []]) =>
      gate.denies(ability, args);

  static Future<bool> check(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.check(abilities, args);

  static Future<bool> any(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.any(abilities, args);

  static Future<bool> none(
    Iterable<String> abilities, [
    List<Object?> args = const [],
  ]) => gate.none(abilities, args);

  static Future<AuthResponse> authorize(
    String ability, [
    List<Object?> args = const [],
  ]) => gate.authorize(ability, args);

  static Future<AuthResponse> inspect(
    String ability, [
    List<Object?> args = const [],
  ]) => gate.inspect(ability, args);
}
