import 'package:daravel/daravel.dart';

// <dartisan:names>
/// The named routes, as URL builders (written by `dartisan names:sync`).
abstract final class Routes {
  /// `POST /api/auth/login` (`auth.login`).
  static String authLogin({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('auth.login', params: {}, query: query, absolute: absolute);

  /// `POST /api/auth/logout` (`auth.logout`).
  static String authLogout({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('auth.logout', params: {}, query: query, absolute: absolute);

  /// `GET|HEAD /api/auth/me` (`auth.me`).
  static String authMe({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('auth.me', params: {}, query: query, absolute: absolute);

  /// `POST /api/auth/register` (`auth.register`).
  static String authRegister({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('auth.register', params: {}, query: query, absolute: absolute);

  /// `GET|HEAD /api/ping` (`ping`).
  static String ping({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('ping', params: {}, query: query, absolute: absolute);

  /// `GET|HEAD /api/users` (`users.index`).
  static String usersIndex({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('users.index', params: {}, query: query, absolute: absolute);

  /// `GET|HEAD /api/users/{id}` (`users.show`).
  static String usersShow({
    required Object id,
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl(
    'users.show',
    params: {'id': id},
    query: query,
    absolute: absolute,
  );

  /// `POST /api/users` (`users.store`).
  static String usersStore({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('users.store', params: {}, query: query, absolute: absolute);

  /// `PATCH /api/users/{id}` (`users.update`).
  static String usersUpdate({
    required Object id,
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl(
    'users.update',
    params: {'id': id},
    query: query,
    absolute: absolute,
  );

  /// `GET|HEAD /` (`welcome`).
  static String welcome({
    Map<String, Object?> query = const {},
    bool absolute = false,
  }) => routeUrl('welcome', params: {}, query: query, absolute: absolute);
}

/// The route names, for APIs that take a name (written by `dartisan names:sync`).
abstract final class RouteNames {
  static const authLogin = 'auth.login';
  static const authLogout = 'auth.logout';
  static const authMe = 'auth.me';
  static const authRegister = 'auth.register';
  static const ping = 'ping';
  static const usersIndex = 'users.index';
  static const usersShow = 'users.show';
  static const usersStore = 'users.store';
  static const usersUpdate = 'users.update';
  static const welcome = 'welcome';
}

/// The abilities: `Gate.define` names, then the policy abilities (written by `dartisan names:sync`).
abstract final class Abilities {
  static const create = Ability('create');
  static const delete = Ability('delete');
  static const forceDelete = Ability('forceDelete');
  static const restore = Ability('restore');
  static const update = Ability('update');
  static const view = Ability('view');
  static const viewAny = Ability('viewAny');
}

/// The named rate limiters, for `Mw.throttle(...)` (written by `dartisan names:sync`).
abstract final class RateLimiters {
  static const login = 'login';
  static const register = 'register';
}

/// The auth guards (written by `dartisan names:sync`).
abstract final class Guards {
  static const token = 'token';
}

/// The storage disks (written by `dartisan names:sync`).
abstract final class Disks {
  static const local = 'local';
  static const public = 'public';
}

/// The database connections (written by `dartisan names:sync`).
abstract final class Connections {
  static const mariadb = 'mariadb';
  static const mysql = 'mysql';
  static const pgsql = 'pgsql';
  static const sqlite = 'sqlite';
}
// </dartisan:names>
