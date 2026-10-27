import 'package:daravel/daravel.dart';

/// 403 from the `role`, `permission` and `role_or_permission` middleware,
/// with spatie/laravel-permission's messages.
final class UnauthorizedException extends HttpException {
  const UnauthorizedException(
    String message, {
    this.requiredRoles = const [],
    this.requiredPermissions = const [],
  }) : super(403, message);

  factory UnauthorizedException.forRoles(
    List<String> roles, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have the right roles.'
    '${display ? ' Necessary roles are ${roles.join(', ')}' : ''}',
    requiredRoles: roles,
  );

  factory UnauthorizedException.forPermissions(
    List<String> permissions, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have the right permissions.'
    '${display ? ' Necessary permissions are ${permissions.join(', ')}' : ''}',
    requiredPermissions: permissions,
  );

  factory UnauthorizedException.forRolesOrPermissions(
    List<String> rolesOrPermissions, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have any of the necessary access rights.'
    '${display ? ' Necessary roles or permissions are ${rolesOrPermissions.join(', ')}' : ''}',
    requiredPermissions: rolesOrPermissions,
  );

  factory UnauthorizedException.notLoggedIn() =>
      const UnauthorizedException('User is not logged in.');

  factory UnauthorizedException.missingTraitHasRoles(Object user) =>
      UnauthorizedException(
        'Authorizable class `${user.runtimeType}` must use the HasRoles mixin.',
      );

  final List<String> requiredRoles;
  final List<String> requiredPermissions;
}

final class RoleDoesNotExist extends DaravelException {
  RoleDoesNotExist.named(String name, String guard)
    : super('There is no role named `$name` for guard `$guard`.');

  RoleDoesNotExist.withId(Object id, String guard)
    : super('There is no role with ID `$id` for guard `$guard`.');
}

final class PermissionDoesNotExist extends DaravelException {
  PermissionDoesNotExist.named(String name, String guard)
    : super('There is no permission named `$name` for guard `$guard`.');

  PermissionDoesNotExist.withId(Object id, String guard)
    : super('There is no [permission] with ID `$id` for guard `$guard`.');
}

final class RoleAlreadyExists extends DaravelException {
  RoleAlreadyExists(String name, String guard)
    : super('A role `$name` already exists for guard `$guard`.');
}

final class PermissionAlreadyExists extends DaravelException {
  PermissionAlreadyExists(String name, String guard)
    : super('A `$name` permission already exists for guard `$guard`.');
}

final class GuardDoesNotMatch extends DaravelException {
  GuardDoesNotMatch(String given, String expected)
    : super(
        'The given role or permission should use guard `$expected` instead '
        'of `$given`.',
      );
}
