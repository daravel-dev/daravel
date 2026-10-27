import 'dart:io';

import 'package:args/command_runner.dart' show UsageException;
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'models.dart';
import 'registrar.dart';

/// The `permission:*` commands, for `bootstrap/commands.dart`:
///
/// ```dart
/// final List<CommandFactory> commands = [...permissionCommands];
/// ```
const List<CommandFactory> permissionCommands = [
  PermissionCreateRoleCommand.new,
  PermissionCreatePermissionCommand.new,
  PermissionAssignCommand.new,
  PermissionRevokeCommand.new,
  PermissionShowCommand.new,
  PermissionCacheResetCommand.new,
];

String? _guard(DaravelCommand command) =>
    command.argResults?['guard'] as String?;

/// `permission:create-role <name> [--guard] [--permissions=a,b]`
/// (Spatie's `permission:create-role`).
final class PermissionCreateRoleCommand extends DaravelCommand {
  PermissionCreateRoleCommand(super.createApp) {
    argParser
      ..addOption('guard', help: 'The guard (default: PERMISSION_GUARD).')
      ..addOption(
        'permissions',
        help: 'Comma-separated permissions to give it (created if missing).',
      );
  }

  @override
  String get name => 'permission:create-role';

  @override
  String get description => 'Creates a role (and gives it permissions).';

  @override
  Future<int> run() => withApp((app) async {
    final name = argResults!.rest.firstOrNull;
    if (name == null) {
      stderr.writeln('Usage: dartisan permission:create-role <name>');
      return 64;
    }
    final role = await Role.findOrCreate(name, guard: _guard(this));
    final permissions = [
      for (final permission
          in (argResults!['permissions'] as String? ?? '').split(','))
        if (permission.trim().isNotEmpty)
          await Permission.findOrCreate(
            permission.trim(),
            guard: role.guardName,
          ),
    ];
    if (permissions.isNotEmpty) {
      await role.givePermissionTo(permissions);
    }
    stdout.writeln('Role `${role.name}` (guard `${role.guardName}`) ready.');
    return 0;
  });
}

/// `permission:create-permission <name> [--guard]`.
final class PermissionCreatePermissionCommand extends DaravelCommand {
  PermissionCreatePermissionCommand(super.createApp) {
    argParser.addOption(
      'guard',
      help: 'The guard (default: PERMISSION_GUARD).',
    );
  }

  @override
  String get name => 'permission:create-permission';

  @override
  String get description => 'Creates a permission.';

  @override
  Future<int> run() => withApp((app) async {
    final name = argResults!.rest.firstOrNull;
    if (name == null) {
      stderr.writeln('Usage: dartisan permission:create-permission <name>');
      return 64;
    }
    final permission = await Permission.findOrCreate(name, guard: _guard(this));
    stdout.writeln(
      'Permission `${permission.name}` (guard `${permission.guardName}`) ready.',
    );
    return 0;
  });
}

abstract base class _AssignmentCommand extends DaravelCommand {
  _AssignmentCommand(super.createApp) {
    argParser
      ..addOption('guard', help: 'The guard (default: PERMISSION_GUARD).')
      ..addOption(
        'model',
        defaultsTo: r'App\Models\User',
        help: 'The model type stored in model_has_roles.',
      );
  }

  Future<void> apply(String type, Object id, Role role);

  @override
  Future<int> run() => withApp((app) async {
    final [id, roleName] = argResults!.rest.length == 2
        ? argResults!.rest
        : (throw UsageException('Expected <model-id> <role>.', usage));
    final role = await Role.findByName(roleName, guard: _guard(this));
    await apply(argResults!['model'] as String, int.tryParse(id) ?? id, role);
    await PermissionRegistrar.current.forgetCachedPermissions();
    stdout.writeln('Done.');
    return 0;
  });
}

/// `permission:assign <model-id> <role> [--model] [--guard]`.
final class PermissionAssignCommand extends _AssignmentCommand {
  PermissionAssignCommand(super.createApp);

  @override
  String get name => 'permission:assign';

  @override
  String get description => 'Gives a role to a model (a user by default).';

  @override
  Future<void> apply(String type, Object id, Role role) => DB
      .table('model_has_roles')
      .insertOrIgnore({'role_id': role.id, 'model_type': type, 'model_id': id});
}

/// `permission:revoke <model-id> <role> [--model] [--guard]`.
final class PermissionRevokeCommand extends _AssignmentCommand {
  PermissionRevokeCommand(super.createApp);

  @override
  String get name => 'permission:revoke';

  @override
  String get description => 'Takes a role away from a model.';

  @override
  Future<void> apply(String type, Object id, Role role) => DB
      .table('model_has_roles')
      .where('role_id', role.id)
      .where('model_type', type)
      .where('model_id', id)
      .delete();
}

/// `permission:show [--guard]`: roles against permissions, as Spatie's.
final class PermissionShowCommand extends DaravelCommand {
  PermissionShowCommand(super.createApp) {
    argParser.addOption('guard', help: 'Only this guard.');
  }

  @override
  String get name => 'permission:show';

  @override
  String get description => 'Shows which role has which permission.';

  @override
  Future<int> run() => withApp((app) async {
    final guard = _guard(this);
    final guards = guard != null
        ? [guard]
        : [
            for (final row
                in await DB
                    .table('roles')
                    .select(['guard_name'])
                    .distinct()
                    .orderBy('guard_name')
                    .get())
              '${row['guard_name']}',
          ];
    for (final name in guards) {
      final roles = await Role.query()
          .where('guard_name', name)
          .orderBy('name')
          .get();
      final permissions = [
        for (final row
            in await DB
                .table('permissions')
                .where('guard_name', name)
                .orderBy('name')
                .select(['name'])
                .get())
          '${row['name']}',
      ];
      final granted = {
        for (final role in roles)
          role.name: (await role.permissionNames()).toSet(),
      };
      stdout.writeln('Guard: $name');
      final width = [
        'Permission'.length,
        ...permissions.map((p) => p.length),
      ].reduce((a, b) => a > b ? a : b);
      stdout.writeln(
        '${'Permission'.padRight(width)}  ${roles.map((r) => r.name).join('  ')}',
      );
      for (final permission in permissions) {
        final marks = [
          for (final role in roles)
            (granted[role.name]!.contains(permission) ? '✔' : '·').padRight(
              role.name.length,
            ),
        ];
        stdout.writeln('${permission.padRight(width)}  ${marks.join('  ')}');
      }
      stdout.writeln();
    }
    return 0;
  });
}

/// `permission:cache-reset`: forgets the cached roles and permissions of
/// every isolate.
final class PermissionCacheResetCommand extends DaravelCommand {
  PermissionCacheResetCommand(super.createApp);

  @override
  String get name => 'permission:cache-reset';

  @override
  String get description => 'Forgets the cached roles and permissions.';

  @override
  Future<int> run() => withApp((app) async {
    await PermissionRegistrar.current.forgetCachedPermissions();
    stdout.writeln('Permission cache flushed.');
    return 0;
  });
}
