import 'package:daravel/daravel.dart';

/// spatie/laravel-permission's five tables (v6, without teams), with its
/// column, key and index names, so a Laravel application can share them.
///
/// It creates nothing when `permissions` exists already: a Laravel
/// application that ran Spatie's own migration (under its own timestamped
/// name) owns the tables.
final class CreatePermissionTables extends Migration {
  const CreatePermissionTables();

  @override
  String get name => '2026_10_27_000000_create_permission_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    if (await schema.hasTable('permissions')) {
      return;
    }
    await schema.create('permissions', (table) {
      table.id();
      table.string('name');
      table.string('guard_name');
      table.timestamps();
      table.unique(['name', 'guard_name']);
    });
    await schema.create('roles', (table) {
      table.id();
      table.string('name');
      table.string('guard_name');
      table.timestamps();
      table.unique(['name', 'guard_name']);
    });
    await schema.create('model_has_permissions', (table) {
      table.unsignedBigInteger('permission_id');
      table.string('model_type');
      table.unsignedBigInteger('model_id');
      table.index([
        'model_id',
        'model_type',
      ], name: 'model_has_permissions_model_id_model_type_index');
      table
          .foreign(['permission_id'])
          .references('id')
          .on('permissions')
          .cascadeOnDelete();
      table.primary([
        'permission_id',
        'model_id',
        'model_type',
      ], name: 'model_has_permissions_permission_model_type_primary');
    });
    await schema.create('model_has_roles', (table) {
      table.unsignedBigInteger('role_id');
      table.string('model_type');
      table.unsignedBigInteger('model_id');
      table.index([
        'model_id',
        'model_type',
      ], name: 'model_has_roles_model_id_model_type_index');
      table.foreign(['role_id']).references('id').on('roles').cascadeOnDelete();
      table.primary([
        'role_id',
        'model_id',
        'model_type',
      ], name: 'model_has_roles_role_model_type_primary');
    });
    await schema.create('role_has_permissions', (table) {
      table.unsignedBigInteger('permission_id');
      table.unsignedBigInteger('role_id');
      table
          .foreign(['permission_id'])
          .references('id')
          .on('permissions')
          .cascadeOnDelete();
      table.foreign(['role_id']).references('id').on('roles').cascadeOnDelete();
      table.primary([
        'permission_id',
        'role_id',
      ], name: 'role_has_permissions_permission_id_role_id_primary');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    for (final table in [
      'role_has_permissions',
      'model_has_roles',
      'model_has_permissions',
      'roles',
      'permissions',
    ]) {
      await schema.dropIfExists(table);
    }
  }
}
