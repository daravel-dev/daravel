<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_activitylog

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_activitylog/README.id.md)

Model change history and an activity log for [Daravel](https://pub.dev/packages/daravel),
in the `activity_log` table of [spatie/laravel-activitylog](https://spatie.be/docs/laravel-activitylog)
v4: a Laravel application using Spatie and a Daravel application share the
table, and each reads the activities the other wrote.

```bash
dart pub add daravel_activitylog
```

```dart
// bootstrap/app.dart
import 'package:daravel_activitylog/daravel_activitylog.dart';

Application createApp() => Application.configure(basePath: '.')
    .withActivityLog()
    .withMigrations([...migrations, const CreateActivityLogTable()])
    // ...
    .create();

final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition = ModelDefinition(
    table: 'assessments',
    factory: Assessment.new,
    observers: [ActivityLogObserver<Assessment>()],
  );
  // ...
  @override
  LogOptions get activitylogOptions =>
      LogOptions.defaults().logOnly(['score', 'status']).logOnlyDirty();
}
```

```dart
await exam.update({'score': 95}); // {attributes: {score: 95}, old: {score: 60}}
await activity('security').performedOn(exam).log('Exam locked');
await exam.activities().latest().get();
```

- `LogsActivity` records `created`, `updated` with old values, `deleted`
  and `restored` as Spatie does, with Spatie's `LogOptions` (`logOnly`,
  relation and JSON attributes, `logOnlyDirty`, `dontSubmitEmptyLogs`,
  ...).
- `activity()` with placeholders, the request's user as causer,
  `LogBatch.within`, `ActivityLog.withoutLogs`, and `Activity` with
  Spatie's scopes; `activitylog:clean`.
- Activities are written in the model's transaction, and a disabled log or
  a batch lasts for one callback, not the whole process.
- Tested on SQLite, PostgreSQL and MariaDB, and against Laravel 12 with
  Spatie 4.10.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/activitylog.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. spatie/laravel-activitylog is Spatie's
MIT-licensed package; Daravel only shares its database layout. Daravel is
an independent project, not affiliated with or endorsed by any of them.
