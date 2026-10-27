// The Daravel side of bench/interop/activitylog.sh: one step per run, on
// the SQLite database a Laravel application with spatie/laravel-activitylog
// uses too.
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';

/// The same options as the Laravel side's User.
final class User extends Model
    with AuthenticatableModel, LogsActivity, CausesActivity {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    observers: [ActivityLogObserver<User>()],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  @override
  LogOptions get activitylogOptions => LogOptions.defaults().logOnly([
    'name',
    'email',
    'created_at',
  ]).logOnlyDirty();
}

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.current.path)
      .withActivityLog()
      .withModels([User.definition])
      .withEnv({'APP_ENV': 'testing', 'LOG_LEVEL': 'error'})
      .create();
  await app.boot();
  final out = await app.run(() async {
    final user = (await User.definition.query().find(int.parse(args[1])))!;
    switch (args.first) {
      case 'read':
        final rows = await Activity.query().orderBy('id').get();
        return jsonEncode([
          for (final activity in rows)
            if (activity.logName == 'security')
              [
                activity.description,
                activity.logName,
                activity.properties,
                (await activity.subject())?.getAttr<String>('name'),
                (await activity.causer())?.getAttr<String>('name'),
                activity.batchUuid != null,
              ]
            else
              [activity.event, activity.properties],
        ]);
      case 'write':
        await user.update({'name': 'Ana C'});
        await LogBatch.within((_) async {
          await activity('daravel')
              .performedOn(user)
              .causedBy(user)
              .withProperties({'ip': '10.0.0.8'})
              .log('Daravel :causer.name');
          await User.definition.query().create({
            'name': 'Bo',
            'email': 'bo@example.com',
            'password': 'x',
          });
        });
        return 'logged';
    }
    return 'unknown step';
  });
  stdout.writeln(out);
  await app.shutdown();
}
