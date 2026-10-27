import 'package:daravel/daravel.dart';

import 'exceptions.dart';
import 'registrar.dart';

/// A role (`roles`, spatie/laravel-permission's table).
final class Role extends Model {
  static final ModelDefinition<Role> definition = ModelDefinition<Role>(
    table: 'roles',
    factory: Role.new,
    fillable: ['name', 'guard_name'],
    morphClass: r'Spatie\Permission\Models\Role',
  );

  @override
  ModelDefinition<Role> get modelDefinition => Role.definition;

  int get id => (getAttr<num>('id')).toInt();
  String get name => getAttr('name');
  String get guardName => getAttr('guard_name');

  static ModelQuery<Role> query() => definition.query();

  /// Creates a role; throws [RoleAlreadyExists] when [guard] has one by
  /// that name.
  static Future<Role> create(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    if (await _find(name, guardName) != null) {
      throw RoleAlreadyExists(name, guardName);
    }
    final role = await query().create({'name': name, 'guard_name': guardName});
    await PermissionRegistrar.current.forgetCachedPermissions();
    return role;
  }

  static Future<Role?> _find(String name, String guard) =>
      query().where('name', name).where('guard_name', guard).first();

  /// Throws [RoleDoesNotExist] when there is none.
  static Future<Role> findByName(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    return await _find(name, guardName) ??
        (throw RoleDoesNotExist.named(name, guardName));
  }

  static Future<Role> findById(int id, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    return await query()
            .where('id', id)
            .where('guard_name', guardName)
            .first() ??
        (throw RoleDoesNotExist.withId(id, guardName));
  }

  static Future<Role> findOrCreate(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    return await _find(name, guardName) ?? create(name, guard: guardName);
  }

  /// The permission names this role grants.
  Future<List<String>> permissionNames() async => [
    for (final row
        in await DB
            .table('role_has_permissions')
            .join(
              'permissions',
              'permissions.id',
              '=',
              'role_has_permissions.permission_id',
            )
            .where('role_has_permissions.role_id', id)
            .orderBy('permissions.name')
            .select(['permissions.name'])
            .get())
      '${row['name']}',
  ];

  /// Grants [permissions] (names, [Permission]s, or a list of them) of this
  /// role's guard; names must exist ([PermissionDoesNotExist]).
  Future<void> givePermissionTo(Object permissions) async {
    for (final permission in await Permission.resolve(permissions, guardName)) {
      await DB.table('role_has_permissions').insertOrIgnore({
        'permission_id': permission.id,
        'role_id': id,
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
          .table('role_has_permissions')
          .where('role_id', id)
          .whereIn('permission_id', ids)
          .delete();
    }
    await PermissionRegistrar.current.forgetCachedPermissions();
  }

  /// Replaces this role's permissions with [permissions].
  Future<void> syncPermissions(Object permissions) async {
    final resolved = await Permission.resolve(permissions, guardName);
    await DB.table('role_has_permissions').where('role_id', id).delete();
    await givePermissionTo(resolved);
  }

  Future<bool> hasPermissionTo(String permission) async {
    final names = await permissionNames();
    return PermissionRegistrar.current.config.wildcard
        ? PermissionRegistrar.implies(names, permission)
        : names.contains(permission);
  }

  @override
  Future<bool> delete() async {
    final deleted = await super.delete();
    // Without foreign keys (SQLite off), clear the pivots as cascades would.
    await DB.table('role_has_permissions').where('role_id', id).delete();
    await DB.table('model_has_roles').where('role_id', id).delete();
    await PermissionRegistrar.current.forgetCachedPermissions();
    return deleted;
  }
}

/// A permission (`permissions`, spatie/laravel-permission's table).
final class Permission extends Model {
  static final ModelDefinition<Permission> definition =
      ModelDefinition<Permission>(
        table: 'permissions',
        factory: Permission.new,
        fillable: ['name', 'guard_name'],
        morphClass: r'Spatie\Permission\Models\Permission',
      );

  @override
  ModelDefinition<Permission> get modelDefinition => Permission.definition;

  int get id => (getAttr<num>('id')).toInt();
  String get name => getAttr('name');
  String get guardName => getAttr('guard_name');

  static ModelQuery<Permission> query() => definition.query();

  /// Creates a permission; throws [PermissionAlreadyExists] when [guard] has
  /// one by that name.
  static Future<Permission> create(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    if (await _find(name, guardName) != null) {
      throw PermissionAlreadyExists(name, guardName);
    }
    final permission = await query().create({
      'name': name,
      'guard_name': guardName,
    });
    await PermissionRegistrar.current.forgetCachedPermissions();
    return permission;
  }

  static Future<Permission?> _find(String name, String guard) =>
      query().where('name', name).where('guard_name', guard).first();

  static Future<Permission> findByName(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    return await _find(name, guardName) ??
        (throw PermissionDoesNotExist.named(name, guardName));
  }

  static Future<Permission> findOrCreate(String name, {String? guard}) async {
    final guardName = guard ?? PermissionRegistrar.current.config.guard;
    return await _find(name, guardName) ?? create(name, guard: guardName);
  }

  /// [permissions] (a name, a [Permission], or a list of them) as stored
  /// permissions of [guard]; a [Permission] of another guard throws
  /// [GuardDoesNotMatch].
  static Future<List<Permission>> resolve(
    Object permissions,
    String guard,
  ) async => [
    for (final item in permissions is Iterable ? permissions : [permissions])
      switch (item) {
        final Permission permission when permission.guardName == guard =>
          permission,
        final Permission permission => throw GuardDoesNotMatch(
          permission.guardName,
          guard,
        ),
        _ => await findByName('$item', guard: guard),
      },
  ];

  @override
  Future<bool> delete() async {
    final deleted = await super.delete();
    await DB.table('role_has_permissions').where('permission_id', id).delete();
    await DB.table('model_has_permissions').where('permission_id', id).delete();
    await PermissionRegistrar.current.forgetCachedPermissions();
    return deleted;
  }
}
