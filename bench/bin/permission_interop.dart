// The Daravel side of bench/interop/permission.sh: one step per run, on the
// SQLite database a Laravel application with spatie/laravel-permission
// uses too.
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_permission/daravel_permission.dart';

final class User extends Model with AuthenticatableModel, HasRoles {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.current.path)
      .withPermissions()
      .withEnv({'APP_ENV': 'testing', 'LOG_LEVEL': 'error'})
      .create();
  await app.boot();
  final out = await app.run(() async {
    final user = (await User.definition.query().find(int.parse(args[1])))!;
    switch (args.first) {
      case 'check':
        return 'writer=${await user.hasRole('writer')} '
            'edit=${await user.checkPermissionTo('posts.edit')} '
            'publish=${await user.checkPermissionTo('posts.publish')}';
      case 'grant':
        final editor = await Role.findOrCreate('editor');
        await Permission.findOrCreate('posts.publish');
        await editor.givePermissionTo('posts.publish');
        await user.assignRole(editor);
        return 'granted';
    }
    return 'unknown step';
  });
  stdout.writeln(out);
  await app.shutdown();
}
