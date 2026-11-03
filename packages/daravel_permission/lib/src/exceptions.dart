import 'package:daravel/daravel.dart';

/// 403 from the `role`, `permission` and `role_or_permission` middleware,
/// with spatie/laravel-permission's messages.
final class UnauthorizedException extends HttpException {
  /// A 403 for missing roles or permissions.
  const UnauthorizedException(
    String message, {
    this.requiredRoles = const [],
    this.requiredPermissions = const [],
  }) : super(403, message);

  /// The user lacks every one of the given roles.
  factory UnauthorizedException.forRoles(
    List<String> roles, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have the right roles.'
    '${display ? ' Necessary roles are ${roles.join(', ')}' : ''}',
    requiredRoles: roles,
  );

  /// The user lacks every one of the given permissions.
  factory UnauthorizedException.forPermissions(
    List<String> permissions, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have the right permissions.'
    '${display ? ' Necessary permissions are ${permissions.join(', ')}' : ''}',
    requiredPermissions: permissions,
  );

  /// The user has none of the roles or permissions.
  factory UnauthorizedException.forRolesOrPermissions(
    List<String> rolesOrPermissions, {
    bool display = false,
  }) => UnauthorizedException(
    'User does not have any of the necessary access rights.'
    '${display ? ' Necessary roles or permissions are ${rolesOrPermissions.join(', ')}' : ''}',
    requiredPermissions: rolesOrPermissions,
  );

  /// No user is logged in.
  factory UnauthorizedException.notLoggedIn() =>
      const UnauthorizedException('User is not logged in.');

  /// The user model does not use `HasRoles`.
  factory UnauthorizedException.missingTraitHasRoles(Object user) =>
      UnauthorizedException(
        'Authorizable class `${user.runtimeType}` must use the HasRoles mixin.',
      );

  /// The roles required.
  final List<String> requiredRoles;

  /// The permissions required.
  final List<String> requiredPermissions;
}

/// A role that does not exist.
final class RoleDoesNotExist extends DaravelException {
  /// No role named [name] for [guard].
  RoleDoesNotExist.named(String name, String guard)
    : super('There is no role named `$name` for guard `$guard`.');

  /// No role with [id] for [guard].
  RoleDoesNotExist.withId(Object id, String guard)
    : super('There is no role with ID `$id` for guard `$guard`.');
}

/// A permission that does not exist.
final class PermissionDoesNotExist extends DaravelException {
  /// No permission named [name] for [guard].
  PermissionDoesNotExist.named(String name, String guard)
    : super('There is no permission named `$name` for guard `$guard`.');

  /// No permission with [id] for [guard].
  PermissionDoesNotExist.withId(Object id, String guard)
    : super('There is no [permission] with ID `$id` for guard `$guard`.');
}

/// A role created twice.
final class RoleAlreadyExists extends DaravelException {
  /// The role [name] already exists for [guard].
  RoleAlreadyExists(String name, String guard)
    : super('A role `$name` already exists for guard `$guard`.');
}

/// A permission created twice.
final class PermissionAlreadyExists extends DaravelException {
  /// The permission [name] already exists for [guard].
  PermissionAlreadyExists(String name, String guard)
    : super('A `$name` permission already exists for guard `$guard`.');
}

/// A role or permission of another guard.
final class GuardDoesNotMatch extends DaravelException {
  /// The guard [given] does not match [expected].
  GuardDoesNotMatch(String given, String expected)
    : super(
        'The given role or permission should use guard `$expected` instead '
        'of `$given`.',
      );
}
