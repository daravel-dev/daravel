import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/commands.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

final class User extends Model with AuthenticatableModel, CausesActivity {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  int get id => getAttr<num>('id').toInt();
  String get name => getAttr('name');
}

/// Spatie's README model: a few attributes, only what changed.
final class Assessment extends Model with LogsActivity {
  static final ModelDefinition<Assessment> definition =
      ModelDefinition<Assessment>(
        table: 'assessments',
        factory: Assessment.new,
        fillable: ['title', 'score', 'status', 'meta', 'author_id'],
        casts: {'meta': Cast.json},
        relations: {
          'author': () =>
              BelongsTo<User>(() => User.definition, foreignKey: 'author_id'),
        },
        observers: [ActivityLogObserver<Assessment>()],
      );

  @override
  ModelDefinition<Assessment> get modelDefinition => Assessment.definition;

  static LogOptions options = LogOptions.defaults()
      .logOnly(['title', 'score', 'status'])
      .logOnlyDirty()
      .dontSubmitEmptyLogs()
      .useLogName('assessments');

  @override
  LogOptions get activitylogOptions => options;

  int get id => getAttr<num>('id').toInt();
}

/// Every attribute but the secret, soft deletes, a custom description.
final class Post extends Model with LogsActivity {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title', 'secret'],
    softDeletes: true,
    observers: [ActivityLogObserver<Post>()],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  @override
  LogOptions get activitylogOptions => LogOptions.defaults()
      .logAll()
      .logExcept(['secret', 'id', 'deleted_at'])
      .setDescriptionForEvent((event) => 'Post was $event');

  @override
  void tapActivity(Activity activity, String eventName) {
    activity.setAttr(
      'properties',
      jsonEncode({...activity.properties, 'tapped': eventName}),
    );
  }
}

final class CreateTables extends Migration {
  const CreateTables();

  @override
  String get name => '2026_01_01_000000_create_test_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('users', (table) {
      table.id();
      table.string('name');
      table.timestamps();
    });
    await schema.create('assessments', (table) {
      table.id();
      table.string('title');
      table.integer('score').defaultTo(0);
      table.string('status').defaultTo('draft');
      table.json('meta').nullable();
      table.unsignedBigInteger('author_id').nullable();
      table.timestamps();
    });
    await schema.create('posts', (table) {
      table.id();
      table.string('title');
      table.string('secret').nullable();
      table.timestamps();
      table.softDeletes();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    for (final table in ['posts', 'assessments', 'users']) {
      await schema.dropIfExists(table);
    }
  }
}

/// SQLite always; PostgreSQL and MySQL / MariaDB with `DARAVEL_TEST_PG` and
/// `DARAVEL_TEST_MYSQL`.
void main() {
  group('sqlite', activitylogTests);
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  if (pg != null && pg.isNotEmpty) {
    group(
      'pgsql',
      () => activitylogTests(databaseUrl: pg),
      tags: 'integration',
    );
  }
  final mysql = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (mysql != null && mysql.isNotEmpty) {
    group(
      'mysql',
      () => activitylogTests(databaseUrl: mysql),
      tags: 'integration',
    );
  }
}

void activitylogTests({String? databaseUrl}) {
  late Directory dir;
  final apps = <Application>[];

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'APP_ENV': 'testing',
    'LOG_LEVEL': 'error',
    if (databaseUrl == null)
      'DB_DATABASE': '${dir.path}/app.sqlite'
    else
      'DB_URL': databaseUrl,
    ...extra,
  };

  Future<Application> boot([Map<String, String> extra = const {}]) async {
    final app = Application.configure(basePath: dir.path)
        .withActivityLog()
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withEnv(env(extra))
        .withMigrations(const [CreateTables(), CreateActivityLogTable()])
        .withModels([User.definition, Assessment.definition, Post.definition])
        .withAuth((auth) {
          auth.register(
            'token',
            ClosureGuard<User>(
              name: 'token',
              resolver: (request) async {
                final token = request.bearerToken();
                return token == null
                    ? null
                    : User.definition.query().find(int.parse(token));
              },
            ),
          );
        })
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router.put('/assessments/{id}', (Request request) async {
              final assessment = (await Assessment.definition.query().find(
                int.parse(request.routeParams['id']!),
              ))!;
              await assessment.update({'score': 95, 'status': 'graded'});
              return {'ok': true};
            });
          },
        )
        .create();
    await app.boot();
    apps.add(app);
    return app;
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_activity_'));

  tearDown(() async {
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    Clock.restore();
    dir.deleteSync(recursive: true);
  });

  Future<Application> migrated([Map<String, String> extra = const {}]) async {
    final app = await boot(extra);
    await app.run(() async {
      if (databaseUrl != null) {
        final schema = await Schema.builder();
        for (final table in ['activity_log', 'posts', 'assessments', 'users']) {
          await schema.dropIfExists(table);
        }
        if (await schema.hasTable('migrations')) {
          await DB.table('migrations').whereIn('migration', [
            const CreateTables().name,
            const CreateActivityLogTable().name,
          ]).delete();
        }
      }
      await App.make<Migrator>().run();
    });
    return app;
  }

  Future<List<Activity>> activities() => Activity.query().orderBy('id').get();

  Future<Assessment> assessment(Map<String, Object?> attributes) =>
      Assessment.definition.query().create(attributes);

  test('model events, as Spatie records them', () async {
    final app = await migrated();
    await app.run(() async {
      final exam = await assessment({
        'title': 'Exam',
        'score': 60,
        'status': 'in_progress',
      });
      exam
        ..setAttr('score', 95)
        ..setAttr('status', 'graded');
      await exam.save();
      await exam.delete();

      final [created, updated, deleted] = await activities();
      expect(created.logName, 'assessments');
      expect(created.description, 'created');
      expect(created.event, 'created');
      expect(created.subjectType, r'App\Models\Assessment');
      expect(created.subjectId, exam.id);
      expect(created.causerType, isNull);
      expect(created.properties, {
        'attributes': {'title': 'Exam', 'score': 60, 'status': 'in_progress'},
      });
      expect(updated.event, 'updated');
      expect(updated.properties, {
        'attributes': {'score': 95, 'status': 'graded'},
        'old': {'score': 60, 'status': 'in_progress'},
      });
      expect(updated.changes, updated.properties);
      expect(deleted.event, 'deleted');
      expect(deleted.properties, {
        'old': {'title': 'Exam', 'score': 95, 'status': 'graded'},
      });
    });
  });

  test('database defaults are logged, as Spatie reads the row again', () async {
    final app = await migrated();
    await app.run(() async {
      await assessment({'title': 'Quiz'});
      final [created] = await activities();
      expect(created.properties['attributes'], {
        'title': 'Quiz',
        'score': 0,
        'status': 'draft',
      });

      // As in Laravel, the created model does not hold the database's
      // defaults, so its updates compare them with null until it is
      // refreshed.
      final quiz = (await Assessment.definition.query().first())!;
      final made = await assessment({'title': 'Created'});
      await made.update({
        'meta': {'room': 'A'},
      });
      expect((await activities()).last.properties, {
        'attributes': {'status': 'draft', 'score': 0},
        'old': {'status': null, 'score': null},
      });
      // Loaded from the database, it knows them: nothing to log.
      await quiz.update({
        'meta': {'room': 'A'},
      });
      expect(await activities(), hasLength(3));
    });
  });

  test('empty logs, ignored changes, a disabled model', () async {
    final app = await migrated();
    await app.run(() async {
      final exam = await assessment({
        'title': 'Exam',
        'score': 1,
        'status': 'draft',
      });
      // Not a logged attribute: with dontSubmitEmptyLogs, nothing.
      await exam.update({
        'meta': {'room': 'A'},
      });
      expect(await activities(), hasLength(1));

      final previous = Assessment.options;
      Assessment.options = LogOptions.defaults()
          .logOnly(['score'])
          .dontLogIfAttributesChangedOnly(['meta', 'updated_at']);
      await exam.update({
        'meta': {'room': 'B'},
      });
      expect(await activities(), hasLength(1));
      await exam.update({'score': 2});
      expect(await activities(), hasLength(2));
      Assessment.options = previous;

      exam.disableLogging();
      await exam.update({'score': 3});
      expect(await activities(), hasLength(2));
    });
  });

  test('json paths, relation attributes and dates', () async {
    final app = await migrated();
    await app.run(() async {
      final ana = await User.definition.query().create({'name': 'Ana'});
      final previous = Assessment.options;
      Assessment.options = LogOptions.defaults().logOnly([
        'meta->room.name',
        'author.name',
        'created_at',
      ]);
      Clock.travelTo(DateTime.utc(2026, 10, 28, 7, 30));
      await assessment({
        'title': 'Exam',
        'meta': {
          'room': {'name': 'A-1', 'floor': 2},
        },
        'author_id': ana.id,
      });
      Assessment.options = previous;
      final [created] = await activities();
      expect(created.properties['attributes'], {
        'meta': {
          'room': {'name': 'A-1'},
        },
        'author.name': 'Ana',
        'created_at': '2026-10-28T07:30:00.000000Z',
      });
    });
  });

  test('soft deletes and restores, every attribute but the excluded', () async {
    final app = await migrated();
    await app.run(() async {
      final post = await Post.definition.query().create({
        'title': 'Hello',
        'secret': 'hunter2',
      });
      await post.delete();
      await post.restore();

      final rows = await activities();
      expect(
        [for (final a in rows) a.event],
        [
          'created',
          'deleted',
          // Laravel's restore() saves deleted_at and updated_at, so Spatie
          // logs the update as well as the restore.
          'updated',
          'restored',
        ],
      );
      expect(rows.first.description, 'Post was created');
      final attributes =
          rows.first.properties['attributes']! as Map<String, Object?>;
      expect(
        attributes.keys,
        unorderedEquals(['title', 'created_at', 'updated_at']),
      );
      expect(rows.first.properties['tapped'], 'created');
      expect(rows[1].properties.keys, unorderedEquals(['old', 'tapped']));
    });
  });

  test('a rollback removes the activity with the change', () async {
    final app = await migrated();
    await app.run(() async {
      await expectLater(
        DB.transaction(() async {
          await assessment({'title': 'Exam'});
          throw StateError('rolled back');
        }),
        throwsStateError,
      );
      expect(await activities(), isEmpty);
    });
  });

  test('the authenticated user is the causer', () async {
    final app = await migrated();
    final (userId, examId) = await app.run(() async {
      final ana = await User.definition.query().create({'name': 'Ana'});
      final exam = await assessment({'title': 'Exam', 'score': 60});
      return (ana.id, exam.id);
    });
    final response = await app.handle(
      Request.fake(
        method: 'PUT',
        path: '/assessments/$examId',
        headers: {'authorization': 'Bearer $userId'},
      ),
    );
    expect(response.status, 200);
    await app.run(() async {
      final rows = await activities();
      expect(rows.first.causerId, isNull, reason: 'created outside a request');
      final updated = rows.last;
      expect(updated.causerType, r'App\Models\User');
      expect(updated.causerId, userId);
      final causer = await updated.causer();
      expect(causer, isA<User>());
      expect((causer! as User).name, 'Ana');
      final ana = (await User.definition.query().find(userId))!;
      expect(await ana.actions().get(), hasLength(1));
    });
  });

  test('activity() by hand, placeholders, causers', () async {
    final app = await migrated();
    await app.run(() async {
      final ana = await User.definition.query().create({'name': 'Ana'});
      final exam = await assessment({'title': 'Exam'});

      final logged = (await activity('security')
          .performedOn(exam)
          .causedBy(ana)
          .withProperties({'ip': '10.0.0.7', 'at': DateTime.utc(2026)})
          .withProperty('tab_switches', 3)
          .event('locked')
          .log(
            ':causer.name locked :subject.title from :properties.ip :unknown.x',
          ))!;
      expect(logged.description, 'Ana locked Exam from 10.0.0.7 :unknown.x');
      expect(logged.getExtraProperty('tab_switches'), 3);
      expect(logged.getExtraProperty('at'), '2026-01-01T00:00:00.000000Z');
      expect(logged.getExtraProperty('missing', 'none'), 'none');

      final reread = (await Activity.query().find(logged.id))!;
      expect(reread.logName, 'security');
      expect(reread.event, 'locked');
      expect(await reread.subject(), isA<Assessment>());
      expect(await exam.activities().inLog('security').get(), hasLength(1));
      expect(await Activity.query().causedBy(ana).get(), hasLength(1));
      expect(await Activity.query().forEvent('locked').get(), hasLength(1));

      await ActivityLog.causedBy(ana, () => activity().log('as Ana'));
      expect(
        (await Activity.query().causedBy(ana).get()).map((a) => a.description),
        contains('as Ana'),
      );
      final anonymous = (await activity()
          .causedByAnonymous()
          .tap((a) => a.setAttr('log_name', 'tapped'))
          .log('nobody'))!;
      expect(anonymous.causerId, isNull);
      expect(anonymous.logName, 'tapped');
      expect(anonymous.getAttr<Object?>('properties'), isEmpty);

      final eager = await Activity.query()
          .whereNotNull('causer_id')
          .with_('causer')
          .get();
      expect(eager.first.related<Model?>('causer'), isA<User>());
    });
  });

  test('batches and logging switched off', () async {
    final app = await migrated();
    await app.run(() async {
      final uuid = await LogBatch.within((uuid) async {
        await assessment({'title': 'One'});
        await LogBatch.within((inner) async {
          expect(inner, uuid, reason: 'a nested batch keeps the uuid');
          await activity().log('inside');
        });
        return uuid;
      });
      await activity().log('outside');
      final rows = await activities();
      expect([for (final a in rows) a.batchUuid], [uuid, uuid, null]);
      expect(await Activity.query().forBatch(uuid).get(), hasLength(2));
      expect(await Activity.query().hasBatch().get(), hasLength(2));

      await ActivityLog.withoutLogs(() async {
        expect(await activity().log('dropped'), isNull);
        await assessment({'title': 'Unlogged'});
      });
      expect(await activities(), hasLength(3));
    });

    final off = await boot({'ACTIVITY_LOGGER_ENABLED': 'false'});
    await off.run(() async {
      expect(await activity().log('dropped'), isNull);
      expect(await activities(), hasLength(3));
    });
  });

  test("Spatie's table, and rows a Laravel application wrote", () async {
    final app = await migrated();
    await app.run(() async {
      final schema = await Schema.builder();
      expect(
        [
          for (final column in await schema.getColumns('activity_log'))
            column.name,
        ],
        [
          'id',
          'log_name',
          'description',
          'subject_type',
          'event',
          'subject_id',
          'causer_type',
          'causer_id',
          'properties',
          'batch_uuid',
          'created_at',
          'updated_at',
        ],
      );
      final exam = await assessment({'title': 'Exam'});
      // As spatie/laravel-activitylog 4.10 inserts it.
      await DB.table('activity_log').insert({
        'log_name': 'default',
        'description': 'viewed',
        'subject_type': r'App\Models\Assessment',
        'subject_id': exam.id,
        'causer_type': null,
        'causer_id': null,
        'properties': '[]',
        'batch_uuid': null,
        'event': null,
        'created_at': '2026-10-28 08:00:00',
        'updated_at': '2026-10-28 08:00:00',
      });
      final laravel = (await Activity.query()
          .where('description', 'viewed')
          .first())!;
      expect(laravel.properties, isEmpty);
      expect(laravel.changes, isEmpty);
      expect(laravel.createdAt, DateTime.utc(2026, 10, 28, 8));
      expect((await laravel.subject())! as Assessment, isA<Assessment>());
      final ours = (await activity().performedOn(exam).log('ours'))!;
      final raw = await DB.table('activity_log').where('id', ours.id).first();
      expect(
        '${raw!['created_at']}',
        matches(RegExp(r'^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d')),
      );
      await const CreateActivityLogTable().up(schema); // kept: the table exists
    });
  });

  test('activitylog:clean', () async {
    final app = await migrated();
    await app.run(() async {
      Clock.travelTo(DateTime.utc(2026, 1, 1));
      await activity('old').log('a');
      await activity('kept').log('b');
      Clock.travelTo(DateTime.utc(2026, 10, 1));
      await activity('old').log('c');
      Clock.restore();
    });
    Future<int?> dartisan(List<String> args, [Map<String, String>? extra]) =>
        DartisanRunner(
          () =>
              Application.configure(basePath: dir.path)
                  .withActivityLog()
                  .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
                  .withEnv(env(extra ?? const {}))
                  .create(),
          commands: activitylogCommands,
        ).run(args);

    Clock.travelTo(DateTime.utc(2026, 10, 28));
    expect(await dartisan(['activitylog:clean', '--days=abc']), 1);
    expect(
      await dartisan(['activitylog:clean'], {'APP_ENV': 'production'}),
      1,
      reason: 'needs --force in production',
    );
    expect(await dartisan(['activitylog:clean', 'old', '--days=100']), 0);
    await app.run(() async {
      expect([for (final a in await activities()) a.description], ['b', 'c']);
    });
    expect(await dartisan(['activitylog:clean', '--days=10']), 0);
    await app.run(() async {
      expect(await activities(), isEmpty);
    });
  });
}
