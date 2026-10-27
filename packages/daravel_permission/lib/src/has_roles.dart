import 'package:daravel/daravel.dart';

import 'exceptions.dart';
import 'models.dart';
import 'registrar.dart';

/// Roles and permissions for a model (spatie/laravel-permission's
/// `HasRoles`), stored in `model_has_roles` and `model_has_permissions`
/// under the model's [Model.modelDefinition] morph class
/// (`App\Models\User`), as Laravel stores them:
///
/// ```dart
/// final class User extends Model with AuthenticatableModel, HasRoles { ... }
///
/// await user.assignRole('writer');
/// await user.givePermissionTo('posts.publish');
/// if (await user.hasPermissionTo('posts.edit')) { ... }
/// ```
///
/// Checks read the [PermissionRegistrar]'s cache; changes made through these
/// methods clear it on every isolate.
base mixin HasRoles on Model {
  /// The guard this model's roles and permissions belong to (Spatie's
  /// `$guard_name`); `PERMISSION_GUARD` unless overridden.
  String get guardName => PermissionRegistrar.current.config.guard;

  String get _type => modelDefinition.morphClass;

  Object get _id =>
      key ??
      (throw StateError('Save the $runtimeType before giving it roles.'));

  Future<Access> _access([String? guard]) =>
      PermissionRegistrar.current.accessOf(_type, _id, guard ?? guardName);

  // ---------------------------------------------------------------------
  // Roles.

  Future<List<Role>> _roles(Object roles) async => [
    for (final item in roles is Iterable ? roles : [roles])
      switch (item) {
        final Role role when role.guardName == guardName => role,
        final Role role => throw GuardDoesNotMatch(role.guardName, guardName),
        final int id => await Role.findById(id, guard: guardName),
        _ => await Role.findByName('$item', guard: guardName),
      },
  ];

  /// Gives this model [roles]: a name, a [Role], an id, or a list of them.
  Future<void> assignRole(Object roles) async {
    for (final role in await _roles(roles)) {
      await DB.table('model_has_roles').insertOrIgnore({
        'role_id': role.id,
        'model_type': _type,
        'model_id': _id,
      });
    }
    await PermissionRegistrar.current.forgetCachedPermissions();
  }

  Future<void> removeRole(Object roles) async {
    final ids = [for (final role in await _roles(roles)) role.id];
    if (ids.isNotEmpty) {
      await DB
          .table('model_has_roles')
          .where('model_type', _type)
          .where('model_id', _id)
          .whereIn('role_id', ids)
          .delete();
    }
    await PermissionRegistrar.current.forgetCachedPermissions();
  }

  /// Replaces this model's roles (of its guard) with [roles].
  Future<void> syncRoles(Object roles) async {
    final resolved = await _roles(roles);
    final current = [
      for (final row
          in await DB
              .table('model_has_roles')
              .join('roles', 'roles.id', '=', 'model_has_roles.role_id')
              .where('model_has_roles.model_type', _type)
              .where('model_has_roles.model_id', _id)
              .where('roles.guard_name', guardName)
              .select(['roles.id'])
              .get())
        row['id'],
    ];
    if (current.isNotEmpty) {
      await DB
          .table('model_has_roles')
          .where('model_type', _type)
          .where('model_id', _id)
          .whereIn('role_id', current)
          .delete();
    }
    await assignRole(resolved);
  }

  /// The names in [roles] that can match under [guard]: a [Role] of
  /// another guard never does (Spatie matches a Role object by key, so the
  /// `admin` role of the `admin` guard is not the `admin` role of `web`).
  static List<String> _names(Object roles, String guard) => [
    for (final item in roles is Iterable ? roles : [roles])
      if (item is Role)
        ...[if (item.guardName == guard) item.name]
      else
        // `hasRole('admin|writer')`, as Spatie reads a pipe-separated string.
        ...'$item'.split('|').map((name) => name.trim()),
  ];

  /// Whether this model has any of [roles] (a name, `'a|b'`, a [Role], or a
  /// list).
  Future<bool> hasRole(Object roles, {String? guard}) async {
    final mine = (await _access(guard)).roles;
    return _names(roles, guard ?? guardName).any(mine.contains);
  }

  Future<bool> hasAnyRole(Object roles, {String? guard}) =>
      hasRole(roles, guard: guard);

  Future<bool> hasAllRoles(Object roles, {String? guard}) async {
    final mine = (await _access(guard)).roles;
    return _names(roles, guard ?? guardName).every(mine.contains);
  }

  /// Whether this model's roles are exactly [roles].
  Future<bool> hasExactRoles(Object roles, {String? guard}) async {
    final mine = (await _access(guard)).roles;
    final wanted = _names(roles, guard ?? guardName).toSet();
    return mine.length == wanted.length && mine.containsAll(wanted);
  }

  Future<List<String>> getRoleNames({String? guard}) async =>
      (await _access(guard)).roles.toList()..sort();

  // ---------------------------------------------------------------------
  // Direct permissions.

  Future<void> givePermissionTo(Object permissions) async {
    for (final permission in await Permission.resolve(permissions, guardName)) {
      await DB.table('model_has_permissions').insertOrIgnore({
        'permission_id': permission.id,
        'model_type': _type,
        'model_id': _id,
      });
    }
    await PermissionRegistrar.current.forgetCachedPermissions();
  }

  Future<void> revokePermissionTo(Object permissions) async {
    final ids = [
      for (final p in await Permission.resolve(permissions, guardName)) p.id,
    ];
    if (ids.isNotEmpty) {
      await DB
          .table('model_has_permissions')
          .where('model_type', _type)
          .where('model_id', _id)
          .whereIn('permission_id', ids)
          .delete();
    }
    await PermissionRegistrar.current.forgetCachedPermissions();
  }

  Future<void> syncPermissions(Object permissions) async {
    final resolved = await Permission.resolve(permissions, guardName);
    await DB
        .table('model_has_permissions')
        .where('model_type', _type)
        .where('model_id', _id)
        .delete();
    await givePermissionTo(resolved);
  }

  /// Whether this model has [permission], directly or through a role (with
  /// `PERMISSION_WILDCARD`, also through `posts.*`). Throws
  /// [PermissionDoesNotExist] for a permission no one could have, as Spatie
  /// does; [checkPermissionTo] answers `false` instead.
  Future<bool> hasPermissionTo(String permission, {String? guard}) async {
    final registrar = PermissionRegistrar.current;
    final guardName = guard ?? this.guardName;
    final granted = (await _access(guardName)).permissions;
    if (registrar.config.wildcard) {
      return PermissionRegistrar.implies(granted, permission);
    }
    if (granted.contains(permission)) {
      return true;
    }
    if (!(await registrar.permissionNames(guardName)).contains(permission)) {
      throw PermissionDoesNotExist.named(permission, guardName);
    }
    return false;
  }

  Future<bool> checkPermissionTo(String permission, {String? guard}) async {
    try {
      return await hasPermissionTo(permission, guard: guard);
    } on PermissionDoesNotExist {
      return false;
    }
  }

  Future<bool> hasAnyPermission(List<String> permissions) async {
    for (final permission in permissions) {
      if (await checkPermissionTo(permission)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> hasAllPermissions(List<String> permissions) async {
    for (final permission in permissions) {
      if (!await checkPermissionTo(permission)) {
        return false;
      }
    }
    return true;
  }

  /// Whether [permission] was given to this model itself, not via a role.
  Future<bool> hasDirectPermission(String permission) async =>
      (await DB
          .table('model_has_permissions')
          .join(
            'permissions',
            'permissions.id',
            '=',
            'model_has_permissions.permission_id',
          )
          .where('model_has_permissions.model_type', _type)
          .where('model_has_permissions.model_id', _id)
          .where('permissions.name', permission)
          .where('permissions.guard_name', guardName)
          .count()) >
      0;

  /// Every permission name this model has, directly or through roles.
  Future<List<String>> getAllPermissions({String? guard}) async =>
      (await _access(guard)).permissions.toList()..sort();

  Future<List<String>> getPermissionNames({String? guard}) =>
      getAllPermissions(guard: guard);
}
