import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_permission/commands.dart';
import 'package:daravel_permission/daravel_permission.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

final class User extends Model with AuthenticatableModel, HasRoles {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  int get id => getAttr<num>('id').toInt();
}

/// A model on another guard (an admin panel's `admin` guard).
final class Admin extends Model with AuthenticatableModel, HasRoles {
  static final ModelDefinition<Admin> definition = ModelDefinition<Admin>(
    table: 'users',
    factory: Admin.new,
    fillable: ['name'],
  );

  @override
  ModelDefinition<Admin> get modelDefinition => Admin.definition;

  @override
  String get guardName => 'admin';
}

final class CreateUsers extends Migration {
  const CreateUsers();

  @override
  String get name => '2026_01_01_000000_create_users';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

/// SQLite always; PostgreSQL and MySQL / MariaDB with `DARAVEL_TEST_PG` and
/// `DARAVEL_TEST_MYSQL` (composite keys, cascades and insert-or-ignore on
/// every dialect).
void main() {
  group('sqlite', permissionTests);
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  if (pg != null && pg.isNotEmpty) {
    group('pgsql', () => permissionTests(databaseUrl: pg), tags: 'integration');
  }
  final mysql = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (mysql != null && mysql.isNotEmpty) {
    group(
      'mysql',
      () => permissionTests(databaseUrl: mysql),
      tags: 'integration',
    );
  }
}

void permissionTests({String? databaseUrl}) {
  late Directory dir;
  final apps = <Application>[];

  Future<Application> boot({
    Map<String, String> env = const {},
    CoordinatorChannel? coordinator,
  }) async {
    final app = Application.configure(basePath: dir.path)
        .withPermissions()
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withEnv({
          'APP_ENV': 'testing',
          if (databaseUrl == null)
            'DB_DATABASE': '${dir.path}/app.sqlite'
          else
            'DB_URL': databaseUrl,
          ...env,
        })
        .withMigrations(const [CreateUsers(), CreatePermissionTables()])
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
            router.get('/admin', (_) => {'ok': true}).middleware(const [
              'role:admin|editor',
            ]);
            router.get('/publish', (_) => {'ok': true}).middleware(const [
              'permission:posts.publish',
            ]);
            router.get('/either', (_) => {'ok': true}).middleware(const [
              'role_or_permission:admin|posts.edit',
            ]);
          },
        )
        .create();
    if (coordinator != null) {
      app.coordinator = coordinator;
    }
    await app.boot();
    apps.add(app);
    return app;
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_perm_'));

  tearDown(() async {
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    Clock.restore();
    dir.deleteSync(recursive: true);
  });

  /// Fresh tables (a server database is shared between runs).
  Future<void> migrate(Application app) => app.run(() async {
    if (databaseUrl != null) {
      final schema = await Schema.builder();
      for (final table in [
        'role_has_permissions',
        'model_has_roles',
        'model_has_permissions',
        'roles',
        'permissions',
        'users',
      ]) {
        await schema.dropIfExists(table);
      }
      if (await schema.hasTable('migrations')) {
        await DB.table('migrations').whereIn('migration', [
          const CreateUsers().name,
          const CreatePermissionTables().name,
        ]).delete();
      }
    }
    await App.make<Migrator>().run();
  });

  Future<Application> migrated([Map<String, String> env = const {}]) async {
    final app = await boot(env: env);
    await migrate(app);
    return app;
  }

  Future<User> user(String name) =>
      User.definition.query().create({'name': name});

  test('roles and permissions, as spatie/laravel-permission', () async {
    final app = await migrated();
    await app.run(() async {
      final writer = await Role.create('writer');
      expect(writer.guardName, 'web');
      await Permission.create('posts.edit');
      await Permission.create('posts.publish');
      await writer.givePermissionTo('posts.edit');

      final ana = await user('Ana');
      await ana.assignRole('writer');
      await ana.givePermissionTo('posts.publish');

      expect(await ana.hasRole('writer'), isTrue);
      expect(await ana.hasRole('admin|writer'), isTrue);
      expect(await ana.hasAllRoles(['writer', 'admin']), isFalse);
      expect(await ana.getRoleNames(), ['writer']);
      expect(
        await ana.hasPermissionTo('posts.edit'),
        isTrue,
        reason: 'via role',
      );
      expect(
        await ana.hasPermissionTo('posts.publish'),
        isTrue,
        reason: 'direct',
      );
      expect(await ana.hasDirectPermission('posts.edit'), isFalse);
      expect(await ana.getAllPermissions(), ['posts.edit', 'posts.publish']);

      await expectLater(
        ana.hasPermissionTo('posts.fly'),
        throwsA(
          isA<PermissionDoesNotExist>().having(
            (e) => e.message,
            'message',
            'There is no permission named `posts.fly` for guard `web`.',
          ),
        ),
      );
      expect(await ana.checkPermissionTo('posts.fly'), isFalse);
      await expectLater(
        Role.create('writer'),
        throwsA(
          isA<RoleAlreadyExists>().having(
            (e) => e.message,
            'message',
            'A role `writer` already exists for guard `web`.',
          ),
        ),
      );
      await expectLater(
        ana.assignRole('ghost'),
        throwsA(
          isA<RoleDoesNotExist>().having(
            (e) => e.message,
            'message',
            'There is no role named `ghost` for guard `web`.',
          ),
        ),
      );

      // Rows as Laravel writes them.
      final row = await DB.table('model_has_roles').first();
      expect(row!['model_type'], r'App\Models\User');
      expect('${row['model_id']}', '${ana.id}');
    });
  });

  test('assigning and syncing twice leaves one row each', () async {
    final app = await migrated();
    await app.run(() async {
      await Role.create('a');
      await Role.create('b');
      final bo = await user('Bo');
      await bo.assignRole(['a', 'b']);
      await bo.assignRole('a');
      await bo.syncRoles(['a', 'b']);
      await bo.syncRoles(['a', 'b']);
      expect(await DB.table('model_has_roles').count(), 2);
      await bo.syncRoles('b');
      expect(await bo.getRoleNames(), ['b']);
      await bo.removeRole('b');
      expect(await bo.getRoleNames(), isEmpty);
    });
  });

  test('guards keep their own roles', () async {
    final app = await migrated();
    await app.run(() async {
      await Role.create('admin');
      final adminRole = await Role.create('admin', guard: 'admin');
      final cy = await user('Cy');
      await cy.assignRole('admin');
      final panel = (await Admin.definition.query().find(cy.id))!;
      expect(await panel.hasRole('admin'), isFalse, reason: 'web role only');
      // A Role object of another guard is not the same role, whatever its
      // name (Spatie compares Role objects by key).
      expect(await cy.hasRole(adminRole), isFalse, reason: 'admin guard');
      expect(await cy.hasRole('admin'), isTrue);
      await panel.assignRole(adminRole);
      expect(await panel.hasRole('admin'), isTrue);
      expect(await panel.hasRole(adminRole), isTrue);
      await expectLater(
        cy.assignRole(adminRole),
        throwsA(
          isA<GuardDoesNotMatch>().having(
            (e) => e.message,
            'message',
            'The given role or permission should use guard `web` instead of '
                '`admin`.',
          ),
        ),
      );
    });
  });

  test('a deleted role takes its assignments with it', () async {
    final app = await migrated();
    await app.run(() async {
      final temp = await Role.create('temp');
      await Permission.create('x');
      await temp.givePermissionTo('x');
      final di = await user('Di');
      await di.assignRole(temp);
      await temp.delete();
      expect(await di.getRoleNames(), isEmpty);
      expect(await DB.table('role_has_permissions').count(), 0);
    });
  });

  test('wildcards, as Spatie with enable_wildcard_permission', () async {
    final app = await migrated({'PERMISSION_WILDCARD': 'true'});
    await app.run(() async {
      final editor = await Role.create('editor');
      await Permission.create('posts.*');
      await Permission.create('reports.view,export');
      await editor.givePermissionTo(['posts.*', 'reports.view,export']);
      final ed = await user('Ed');
      await ed.assignRole('editor');
      expect(await ed.hasPermissionTo('posts.edit'), isTrue);
      expect(await ed.hasPermissionTo('posts.edit.own'), isTrue);
      expect(await ed.hasPermissionTo('reports.export'), isTrue);
      expect(await ed.hasPermissionTo('reports.delete'), isFalse);
      expect(await ed.hasPermissionTo('users.delete'), isFalse);
    });
  });

  test('the gate and the middleware see database permissions', () async {
    final app = await migrated({'PERMISSION_SUPER_ADMIN_ROLE': 'root'});
    late User fay;
    late User gil;
    late User root;
    await app.run(() async {
      await Role.create('editor');
      await Role.create('root');
      await Permission.create('posts.edit');
      await Permission.create('posts.publish');
      fay = await user('Fay');
      await fay.assignRole('editor');
      await fay.givePermissionTo('posts.edit');
      gil = await user('Gil');
      root = await user('Root');
      await root.assignRole('root');
      expect(
        await App.make<AuthorizationGate>().forUser(fay).allows('posts.edit'),
        isTrue,
      );
      expect(
        await App.make<AuthorizationGate>()
            .forUser(root)
            .allows('anything.at.all'),
        isTrue,
        reason: 'super admin',
      );
    });

    /// `<status> <message>`.
    Future<String> get(String path, User? as) async {
      final response = await app.handle(
        Request.fake(
          path: path,
          headers: {if (as != null) 'authorization': 'Bearer ${as.id}'},
        ),
      );
      final body = jsonDecode(await response.bodyText()) as Map;
      return '${response.status} ${body['message'] ?? 'ok'}';
    }

    expect(await get('/admin', fay), '200 ok');
    expect(await get('/admin', gil), '403 User does not have the right roles.');
    expect(await get('/admin', null), '403 User is not logged in.');
    expect(
      await get('/publish', fay),
      '403 User does not have the right permissions.',
    );
    expect(await get('/publish', root), '200 ok', reason: 'super admin');
    expect(await get('/either', fay), '200 ok');
    expect(
      await get('/either', gil),
      '403 User does not have any of the necessary access rights.',
    );
  });

  test('a change on one isolate shows on the others within a second; a '
      'change made '
      'outside Daravel within PERMISSION_CACHE_TTL', () async {
    final channel = LocalCoordinatorChannel(createStandardCoordinator());
    final first = await boot(coordinator: channel);
    await migrate(first);
    final second = await boot(coordinator: channel);
    final id = await first.run(() async {
      await Role.create('lead');
      await Role.create('outside');
      final hal = await user('Hal');
      expect(await hal.hasRole('lead'), isFalse);
      return hal.id;
    });
    Future<bool> has(String role) => second.run(() async {
      final hal = (await User.definition.query().find(id))!;
      return hal.hasRole(role);
    });
    expect(await has('lead'), isFalse); // cached on the second isolate

    await first.run(() async {
      await (await User.definition.query().find(id))!.assignRole('lead');
    });
    // The coordinator relays the invalidation at once; the shared version,
    // read at most once a second, is the fallback.
    final deadline = DateTime.now().add(const Duration(milliseconds: 500));
    while (!await has('lead') && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      await has('lead'),
      isTrue,
      reason: 'relayed through the coordinator',
    );

    // A Laravel application writes the pivot itself.
    final start = DateTime.now();
    Clock.fake(start);
    await second.run(() async {
      final outside = await Role.findByName('outside');
      await DB.table('model_has_roles').insert({
        'role_id': outside.id,
        'model_type': r'App\Models\User',
        'model_id': id,
      });
    });
    expect(await has('outside'), isFalse);
    Clock.travelTo(start.add(const Duration(minutes: 6)));
    expect(await has('outside'), isTrue);
  });

  test('the per-isolate access cache is bounded', () async {
    final app = await migrated();
    await app.run(() async {
      final registrar = PermissionRegistrar.current;
      for (var i = 0; i < PermissionRegistrar.maxCachedModels + 50; i++) {
        await registrar.accessOf(r'App\Models\User', i, 'web');
      }
      expect(
        registrar.cachedModels,
        lessThanOrEqualTo(PermissionRegistrar.maxCachedModels),
        reason: 'one entry per model ever checked used to stay for ever',
      );
    });
  });

  test('the permission:* commands', () async {
    final app = await migrated();
    final id = await app.run(() async => (await user('Ivy')).id);
    Future<int?> dartisan(List<String> args) async {
      final runner = DartisanRunner(
        () => Application.configure(basePath: dir.path)
            .withPermissions()
            .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
            .withEnv({
              'APP_ENV': 'testing',
              'LOG_LEVEL': 'error',
              if (databaseUrl == null)
                'DB_DATABASE': '${dir.path}/app.sqlite'
              else
                'DB_URL': databaseUrl,
            })
            .create(),
        commands: permissionCommands,
      );
      return runner.run(args);
    }

    expect(
      await dartisan([
        'permission:create-role',
        'editor',
        '--permissions=posts.edit,posts.publish',
      ]),
      0,
    );
    expect(await dartisan(['permission:create-permission', 'posts.delete']), 0);
    expect(await dartisan(['permission:assign', '$id', 'editor']), 0);
    expect(await dartisan(['permission:show']), 0);
    expect(await dartisan(['permission:cache-reset']), 0);
    await app.run(() async {
      final ivy = (await User.definition.query().find(id))!;
      expect(await ivy.hasRole('editor'), isTrue);
      expect(await ivy.hasPermissionTo('posts.publish'), isTrue);
      expect(await ivy.hasPermissionTo('posts.delete'), isFalse);
    });
    expect(await dartisan(['permission:revoke', '$id', 'editor']), 0);
    // The command ran in another application: seen within a second.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await app.run(() async {
      final ivy = (await User.definition.query().find(id))!;
      expect(await ivy.hasRole('editor'), isFalse);
    });
  });

  group('wildcard matching', () {
    test('Spatie WildcardPermission cases', () {
      expect(wildcardImplies(['posts.*'], 'posts.edit'), isTrue);
      expect(wildcardImplies(['posts'], 'posts.edit'), isTrue);
      expect(wildcardImplies(['posts.edit'], 'posts'), isFalse);
      expect(wildcardImplies(['posts.edit,delete'], 'posts.delete'), isTrue);
      expect(wildcardImplies(['posts.*.own'], 'posts.edit.own'), isTrue);
      expect(wildcardImplies(['posts.*.own'], 'posts.edit.all'), isFalse);
      expect(wildcardImplies(['*'], 'anything.goes'), isTrue);
      expect(wildcardImplies(['users.view'], 'posts.view'), isFalse);
      expect(
        () => wildcardImplies(['posts..edit'], 'posts'),
        throwsFormatException,
      );
    });
  });
}
