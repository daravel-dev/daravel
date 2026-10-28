# Activity log

`daravel_activitylog` records who changed what in your models, and any
other activity you log by hand, in the `activity_log` table of
[spatie/laravel-activitylog](https://spatie.be/docs/laravel-activitylog)
v4. A Laravel application using Spatie and a Daravel application can share
the table: each reads the activities the other wrote, with their subjects,
causers and batches.

```bash
dart pub add daravel_activitylog
```

```dart
// bootstrap/app.dart
import 'package:daravel_activitylog/daravel_activitylog.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withActivityLog()
    .withMigrations([...migrations, const CreateActivityLogTable()])
    .withModels(models)
    // ...
    .create();
```

`CreateActivityLogTable` creates the table of Spatie's three v4 migrations
(`create_activity_log_table`, `add_event_column`, `add_batch_uuid_column`)
with their column order and index names, and does nothing when the table
exists, so a database that ran Spatie's migrations keeps it. Spatie v5
changed the table (`attribute_changes`, no `batch_uuid`); this package
follows v4 (4.x), which Laravel 12 supports alongside v5.

## Logging model changes

A model mixes in `LogsActivity`, says what to record, and lists
`ActivityLogObserver` among its observers (Daravel has no boot hooks to
attach it for you):

```dart
final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition =
      ModelDefinition<Assessment>(
        table: 'assessments',
        factory: Assessment.new,
        fillable: ['title', 'score', 'status'],
        observers: [ActivityLogObserver<Assessment>()],
      );

  @override
  ModelDefinition<Assessment> get modelDefinition => Assessment.definition;

  static ModelQuery<Assessment> query() => definition.query();

  @override
  LogOptions get activitylogOptions => LogOptions.defaults()
      .logOnly(['title', 'score', 'status'])
      .logOnlyDirty()
      .dontSubmitEmptyLogs()
      .useLogName('assessments');
}
```

Saving a change writes one row, as Spatie writes it:

```dart
final exam = (await Assessment.query().find(42))!;
await exam.update({'score': 95, 'status': 'graded'});
```

```json
{
  "log_name": "assessments",
  "description": "updated",
  "event": "updated",
  "subject_type": "App\\Models\\Assessment",
  "subject_id": 42,
  "causer_type": "App\\Models\\User",
  "causer_id": 7,
  "properties": {
    "attributes": {"score": 95, "status": "graded"},
    "old": {"score": 60, "status": "in_progress"}
  }
}
```

`created` stores `attributes`, `updated` adds `old`, `deleted` stores only
`old`, and a soft-deleting model also records `restored`. The values are
read back from the database after the change (Spatie's `fresh()`), so
defaults the database filled in are logged; dates are written as Laravel
serializes them (`2026-10-28T07:30:00.000000Z`), enums as stored.

| `LogOptions` | Records |
| :-- | :-- |
| `logOnly([...])` | these attributes; `author.name` (a relation's column) and `meta->room.name` (inside JSON) too |
| `logAll()` | every attribute, hidden ones included: pair it with `logExcept` |
| `logFillable()` / `logUnguarded()` | the model's `fillable`, or what `guarded` does not list |
| `logExcept([...])` | not these |
| `logOnlyDirty()` | on updates, only the logged attributes that changed |
| `dontSubmitEmptyLogs()` | nothing when no logged attribute changed |
| `dontLogIfAttributesChangedOnly([...])` | nothing when only these changed (`updated_at`, a counter) |
| `useLogName('...')` | the `log_name` (the default log otherwise) |
| `setDescriptionForEvent((event) => ...)` | the description; an empty one logs nothing |
| `useAttributeRawValues([...])` | these as stored, without casts or accessors |

`ActivityLogObserver(recordEvents: [...], doNotRecordEvents: [...])`
replaces or trims the events (Spatie's `$recordEvents` and
`$doNotRecordEvents`). `model.disableLogging()` stops one instance, and
overriding `tapActivity(activity, eventName)` changes an activity before it
is saved.

As in Laravel, a model you just created does not hold the defaults the
database gave it, so its updates compare those columns with `null` until
it is loaded again (`await model.refresh()`). Set them when you create the
model to keep such entries out of the log.

The activity is written in the model's transaction: a rollback removes it
with the change it describes, and the log never shows a change that did
not happen.

## Logging by hand

```dart
await activity('security')
    .performedOn(examSession)
    .causedBy(user)
    .withProperties({'ip': request.ip, 'tab_switches': 3})
    .event('locked')
    .log(':causer.name locked :subject.title from :properties.ip');
```

`:subject.*`, `:causer.*` and `:properties.*` in the description are
replaced by those values, as Spatie does. `causedByAnonymous()`,
`withProperty()`, `createdAt()` and `tap((activity) => ...)` work as in
Spatie.

## Causers

The causer is the authenticated user of the request (the guard named by
`ACTIVITY_LOGGER_AUTH_GUARD`, the request's guard otherwise), when that user
is a model. In a command or a job there is none, unless you choose one:

```dart
await ActivityLog.causedBy(admin, () async {
  await importStudents(file); // every activity inside is caused by admin
});
```

`causedBy` replaces Spatie's `CauserResolver::setCauser()`, and
`ActivityLog.withoutLogs(() async { ... })` its `withoutLogs()`. Both last
for the callback only: what Spatie keeps in singletons is scoped to a zone
here, so one request never switches logging off for the requests beside
it.

## Batches

```dart
await LogBatch.within((uuid) async {
  await session.update({'status': 'finished'});
  await score.update({'total': 90});
});
```

Every activity inside shares one `batch_uuid`, and a batch opened inside
another keeps the outer UUID. `LogBatch.using(uuid, ...)` continues a
batch elsewhere, for example in a job the request dispatched.

## Reading the log

```dart
final history = await exam.activities().latest().take(10).get();
for (final entry in history) {
  final who = await entry.causer();
  print('${who?['name']} ${entry.description} at ${entry.createdAt}');
  print(entry.changes); // {attributes: {...}, old: {...}}
}

await user.actions().get();                 // with CausesActivity on User
await Activity.query().inLog('security').get();
await Activity.query().causedBy(user).forEvent('updated').get();
await Activity.query().forBatch(uuid).get();
await Activity.query().with_('causer').get(); // eager loading
```

`subject()` and `causer()` load the model a `*_type` column names. Without
reflection, Daravel finds it among the models of `withModels(...)` or the
morph map (`Relation.morphMap`); rows written by Laravel store class names
such as `App\Models\User`, which match a model's `morphClass`.
`getExtraProperty('a.b')` reads a nested property.

## Cleaning up

```bash
dartisan activitylog:clean              # older than 365 days
dartisan activitylog:clean security --days=30
```

```dart
// bootstrap/commands.dart
import 'package:daravel_activitylog/commands.dart';

final List<CommandFactory> commands = [...activitylogCommands];

// the scheduler
schedule.command('activitylog:clean').daily();
```

In production the command needs `--force`, as Spatie's asks for
confirmation.

## Configuration

| Variable | Default | |
| :-- | :-- | :-- |
| `ACTIVITY_LOGGER_ENABLED` | `true` | `false` writes nothing |
| `ACTIVITY_LOGGER_TABLE_NAME` | `activity_log` | |
| `ACTIVITY_LOGGER_DB_CONNECTION` | the default | |
| `ACTIVITY_LOGGER_DEFAULT_LOG_NAME` | `default` | |
| `ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS` | `365` | for `activitylog:clean` |
| `ACTIVITY_LOGGER_AUTH_GUARD` | the request's guard | Spatie's `default_auth_driver` |
| `ACTIVITY_LOGGER_SUBJECT_RETURNS_SOFT_DELETED_MODELS` | `false` | |

The first three are Spatie's variables; the others are settings Spatie
keeps in `config/activitylog.php`.

## Sharing the table with Laravel

`bench/interop/activitylog.sh` runs Laravel 12 with
spatie/laravel-activitylog 4.10 and Daravel on one database. Daravel reads
Laravel's created and updated activities, a hand-written activity with its
subject, causer and batch; Laravel reads Daravel's, and a model created by
Daravel logs the same keys and date format as one created by Laravel.

Not ported: Spatie's change pipes (`addLogChange`), its global
`disableLogging()`/`enableLogging()` switches (use `withoutLogs`), and
causers given as an id rather than a model.
