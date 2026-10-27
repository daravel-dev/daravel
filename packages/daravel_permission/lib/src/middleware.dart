import 'package:daravel/daravel.dart';

import 'exceptions.dart';
import 'has_roles.dart';
import 'registrar.dart';

/// Reads `role:admin|writer` and `role:admin,api`: names split on `|`, an
/// optional auth guard after the comma, as spatie/laravel-permission's
/// middleware take them.
({List<String> names, String? guard}) _parse(List<String> params) => (
  names: [
    for (final name in (params.isEmpty ? '' : params.first).split('|'))
      if (name.trim().isNotEmpty) name.trim(),
  ],
  guard: params.length > 1 && params[1].isNotEmpty ? params[1] : null,
);

Future<HasRoles> _user(String? guard) async {
  final user = await Auth.user<Authenticatable>(guard: guard);
  if (user == null) {
    throw UnauthorizedException.notLoggedIn();
  }
  if (user case final HasRoles roles) {
    return roles;
  }
  throw UnauthorizedException.missingTraitHasRoles(user);
}

/// `role:admin|writer[,guard]`: the user has one of the roles (403
/// otherwise).
final class RoleMiddleware implements Middleware {
  RoleMiddleware(List<String> params) : _params = _parse(params);

  final ({List<String> names, String? guard}) _params;

  @override
  Future<Response> handle(Request request, Next next) async {
    final user = await _user(_params.guard);
    if (!await user.hasAnyRole(_params.names)) {
      throw UnauthorizedException.forRoles(
        _params.names,
        display: PermissionRegistrar.current.config.displayRoleInException,
      );
    }
    return next(request);
  }
}

/// `permission:posts.edit|posts.delete[,guard]`: the user can do one of
/// them, through the gate (so gate abilities count too, as Laravel's
/// `canAny`).
final class PermissionMiddleware implements Middleware {
  PermissionMiddleware(List<String> params) : _params = _parse(params);

  final ({List<String> names, String? guard}) _params;

  @override
  Future<Response> handle(Request request, Next next) async {
    final user = await _user(_params.guard);
    final gate = App.make<AuthorizationGate>().forUser(user as Authenticatable);
    if (!await gate.any(_params.names)) {
      throw UnauthorizedException.forPermissions(
        _params.names,
        display:
            PermissionRegistrar.current.config.displayPermissionInException,
      );
    }
    return next(request);
  }
}

/// `role_or_permission:admin|posts.edit[,guard]`: one of the roles, or one
/// of the abilities.
final class RoleOrPermissionMiddleware implements Middleware {
  RoleOrPermissionMiddleware(List<String> params) : _params = _parse(params);

  final ({List<String> names, String? guard}) _params;

  @override
  Future<Response> handle(Request request, Next next) async {
    final user = await _user(_params.guard);
    final gate = App.make<AuthorizationGate>().forUser(user as Authenticatable);
    if (!await gate.any(_params.names) &&
        !await user.hasAnyRole(_params.names)) {
      final config = PermissionRegistrar.current.config;
      throw UnauthorizedException.forRolesOrPermissions(
        _params.names,
        display:
            config.displayRoleInException &&
            config.displayPermissionInException,
      );
    }
    return next(request);
  }
}
