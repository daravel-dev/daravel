import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show Encrypter, daravelVersion;
import 'package:path/path.dart' as p;

import 'generator.dart';
import 'project_commands.dart';
import 'stubs.dart';

/// Where the framework packages come from in a generated `pubspec.yaml`.
sealed class FrameworkSource {
  const FrameworkSource();

  /// Dependency block for [package] (`daravel`, `dartisan_cli`, …).
  String dependency(String package);

  /// Whether every framework package must be pinned with
  /// `dependency_overrides` (git and path sources: the packages depend on
  /// each other by name, which would otherwise resolve from pub.dev).
  bool get needsOverrides => true;
}

/// Published packages on pub.dev (default): a plain `pubspec.yaml` without
/// overrides, like any other application.
final class PubHostedSource extends FrameworkSource {
  const PubHostedSource({this.version = '^$daravelVersion'});

  final String version;

  @override
  String dependency(String package) => '  $package: $version';

  @override
  bool get needsOverrides => false;
}

/// Git dependency on github.com/daravel-dev/daravel (`--source=git`).
final class GitSource extends FrameworkSource {
  const GitSource({
    this.url = 'https://github.com/daravel-dev/daravel.git',
    this.ref = 'main',
  });

  final String url;
  final String ref;

  @override
  String dependency(String package) =>
      '''
  $package:
    git:
      url: $url
      ref: $ref
      path: packages/$package''';
}

/// Local checkout of the framework repository (contributors, CI).
final class PathSource extends FrameworkSource {
  const PathSource(this.repository);

  final String repository;

  @override
  String dependency(String package) {
    final path = p
        .join(p.absolute(repository), 'packages', package)
        .replaceAll(r'\', '/');
    return '''
  $package:
    path: $path''';
  }
}

/// Builds the files of a new project (`dartisan new`).
Map<String, String> newProjectFiles({
  required String package,
  required String appName,
  required FrameworkSource source,
  String template = 'api',
  String? appKey,
}) {
  if (template != 'api' && template != 'minimal') {
    throw ArgumentError.value(template, 'template', 'Use api or minimal.');
  }
  final api = template == 'api';
  final key = appKey ?? Encrypter.generateKey();
  final values = <String, String>{
    'package': package,
    'appName': appName,
    'appKey': key,
    'dependencies': [
      source.dependency('daravel'),
      source.dependency('dartisan_cli'),
    ].join('\n'),
    'devDependencies': source.dependency('daravel_test'),
    'overrides': source.needsOverrides
        ? [
            '',
            '# dartisan_cli and daravel_test depend on daravel and '
                'daravel_lints by name; pin every',
            '# framework package to the same source.',
            'dependency_overrides:',
            source.dependency('daravel'),
            source.dependency('daravel_lints'),
            source.dependency('daravel_test'),
          ].join('\n')
        : '',
  };
  final files = <String, String>{
    'pubspec.yaml': _pubspec,
    'analysis_options.yaml': _analysisOptions,
    '.gitignore': _gitignore,
    '.env.example': _envExample,
    'README.md': _readme,
    'Dockerfile': dockerfileTemplate(),
    '.dockerignore': dockerignoreTemplate,
    'bin/server.dart': _binServer,
    'bin/dartisan.dart': _binDartisan,
    'bootstrap/seeders.dart': api ? _seedersRegistry : _emptySeeders,
    'bootstrap/jobs.dart': _jobsRegistry,
    'bootstrap/listeners.dart': _listenersRegistry,
    'bootstrap/commands.dart': _commandsRegistry,
    'routes/web.dart': _webRoutes,
    'routes/console.dart': api ? _consoleRoutes : _consoleRoutesMinimal,
    'lib/app/http/controllers/ping_controller.dart': _pingController,
    'storage/.gitignore': '*\n!.gitignore\n',
    'test/architecture_test.dart': _architectureTest,
    'dart_test.yaml': _dartTestYaml,
    '.github/workflows/ci.yml': _ciWorkflow,
    if (api) ...{
      'bootstrap/app.dart': _bootstrapApi,
      'bootstrap/migrations.dart': _migrationsRegistry,
      'bootstrap/policies.dart': _policiesRegistry,
      'routes/api.dart': _apiRoutes,
      'lib/app/models/user.dart': _userModel,
      'lib/app/http/controllers/auth_controller.dart': _authController,
      'lib/app/http/requests/register_request.dart': _registerRequest,
      'lib/app/http/resources/user_resource.dart': _userResource,
      'lib/app/policies/user_policy.dart': _userPolicy,
      'database/migrations/m_0001_01_01_000000_create_users_table.dart':
          _usersMigration,
      'database/factories/user_factory.dart': _userFactory,
      'database/seeders/database_seeder.dart': _databaseSeeder,
      'test/feature/auth_test.dart': _authTest,
      'test/conformance/api_contract_test.dart': _conformanceTest,
      'docker-compose.yml': _dockerCompose,
    } else ...{
      'bootstrap/app.dart': _bootstrapMinimal,
      'bootstrap/migrations.dart': _emptyMigrations,
      'bootstrap/policies.dart': _policiesRegistryEmpty,
      'routes/api.dart': _apiRoutesMinimal,
      'test/feature/ping_test.dart': _pingTest,
    },
  };
  return <String, String>{
    for (final entry in files.entries)
      entry.key: renderStub(entry.value, values),
    '.env': setEnvValue(renderStub(_envExample, values), 'APP_KEY', key),
  };
}

/// `new <name> [--template=api|minimal] [--path=<repo>] [--git] [--no-pub]`
final class NewCommand extends Command<int> {
  NewCommand() {
    argParser
      ..addOption(
        'template',
        allowed: ['api', 'minimal'],
        defaultsTo: 'api',
        help: 'Project template.',
      )
      ..addOption(
        'source',
        allowed: ['pub', 'git'],
        defaultsTo: 'pub',
        help:
            'Where the framework packages come from: pub.dev or the git '
            'repository (follow main with --ref).',
      )
      ..addOption(
        'path',
        help: 'Use a local Daravel checkout (overrides --source).',
      )
      ..addOption(
        'ref',
        defaultsTo: 'main',
        help: 'Git ref of the framework (with --source=git).',
      )
      ..addFlag('git', negatable: false, help: 'Initialise a git repository.')
      ..addFlag('no-pub', negatable: false, help: 'Skip `dart pub get`.')
      ..addFlag(
        'force',
        negatable: false,
        help: 'Write into a non-empty directory.',
      );
  }

  @override
  String get name => 'new';

  @override
  String get description => 'Create a new Daravel application.';

  @override
  Future<int> run() async {
    final r = argResults!;
    if (r.rest.isEmpty) {
      usageException('Missing <name> argument (e.g. `dartisan new blog`).');
    }
    final directory = p.absolute(r.rest.first);
    final package = Naming.snake(p.basename(directory));
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(package)) {
      usageException('"$package" is not a valid Dart package name.');
    }
    final dir = Directory(directory);
    if (dir.existsSync() &&
        dir.listSync().isNotEmpty &&
        !(r['force'] as bool)) {
      stderr.writeln('Directory ${r.rest.first} is not empty (use --force).');
      return 1;
    }
    final path = r['path'] as String?;
    final files = newProjectFiles(
      package: package,
      appName: Naming.pascal(package),
      template: r['template'] as String,
      source: path != null
          ? PathSource(path)
          : r['source'] == 'git'
          ? GitSource(ref: r['ref'] as String)
          : const PubHostedSource(),
    );
    for (final entry in files.entries) {
      final file = File(p.join(directory, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    stdout.writeln('Created ${files.length} files in ${r.rest.first}.');
    if (!(r['no-pub'] as bool)) {
      final pub = await Process.run(dartExecutable(), const [
        'pub',
        'get',
      ], workingDirectory: directory);
      stdout.write(pub.stdout);
      if (pub.exitCode != 0) {
        stderr.write(pub.stderr);
        return pub.exitCode;
      }
    }
    if (r['git'] as bool) {
      await Process.run('git', const [
        'init',
        '--quiet',
      ], workingDirectory: directory);
      stdout.writeln('Initialised a git repository.');
    }
    stdout.writeln('''

  cd ${r.rest.first}
  dart run bin/dartisan.dart migrate${r['template'] == 'api' ? ' --seed' : ''}
  dart run bin/dartisan.dart serve --watch
''');
    return 0;
  }
}

const String _pubspec = r'''
name: {{ package }}
description: A Daravel application.
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.13.0

dependencies:
{{ dependencies }}

dev_dependencies:
{{ devDependencies }}
  lints: ^6.0.0
  test: ^1.33.0
{{ overrides }}''';

const String _analysisOptions = r'''
include: package:lints/recommended.yaml

analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
''';

const String _gitignore = r'''
.dart_tool/
build/
*.exe
.env
.env.*
!.env.example
*.sqlite
*.sqlite-*
storage/logs/
openapi.json
''';

const String _envExample = r'''
APP_NAME={{ appName }}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://127.0.0.1:8000
APP_HOST=127.0.0.1
APP_PORT=8000
APP_ISOLATES=1

DB_CONNECTION=sqlite
DB_DATABASE=database/database.sqlite

LOG_CHANNEL=stack
LOG_STACK=console
LOG_LEVEL=debug

CACHE_STORE=memory
QUEUE_CONNECTION=sync
FILESYSTEM_DISK=local
HASH_DRIVER=bcrypt
AUTH_GUARD=token
METRICS_ENABLED=false

# Defaults match Laravel (ADR-024): AES-256-CBC and bcrypt, so a Laravel app
# sharing APP_KEY and the database interoperates without changes.
# APP_CIPHER=AES-256-GCM
# HASH_DRIVER=argon2id
''';

const String _readme = r'''
# {{ appName }}

A [Daravel](https://github.com/daravel-dev/daravel) application.

```bash
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch      # hot reload
dart run bin/dartisan.dart test               # = dart test
dart run bin/dartisan.dart test --conformance # Laravel wire-format contract
dart run bin/dartisan.dart build --docker     # native bundle + Dockerfile
```
''';

const String _binServer = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../bootstrap/app.dart';

/// HTTP entrypoint (`dart run bin/server.dart` or the AOT binary).
Future<void> main(List<String> args) async {
  exitCode = await Application.serveWith(createApp);
}
''';

const String _binDartisan = r'''
import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';

import '../bootstrap/app.dart';
import '../bootstrap/commands.dart';

/// Project-bound CLI: `dart run bin/dartisan.dart <command>`.
Future<void> main(List<String> args) async {
  exitCode = await DartisanRunner(createApp, commands: commands).execute(args);
}
''';

const String _bootstrapApi = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/user.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'policies.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. [env] overrides win over `.env`.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withJobs(jobs)
        .withEvents(registerListeners)
        .withPolicies(registerPolicies)
        .withSchedule(consoleRoutes)
        .withRouting(api: apiRoutes, web: webRoutes, health: '/up')
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[
            RequestIdMiddleware(),
            SecurityHeadersMiddleware(),
            BodyLimitsMiddleware(),
            TrimStringsMiddleware(),
            ConvertEmptyStringsToNullMiddleware(),
          ]);
        })
        .withAuth((auth) {
          auth.token<User>('token', ModelUserProvider<User>(User.definition));
        })
        .withRateLimits((limiter) {
          limiter.define('login', (request) async {
            final email = (await request.all())['email'];
            return Limit.perMinute(5).by('$email|${request.ip}');
          });
          limiter.define(
            'register',
            (request) => Limit.perMinute(5).by(request.ip),
          );
        })
        .create();
''';

const String _bootstrapMinimal = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'policies.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. [env] overrides win over `.env`.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withJobs(jobs)
        .withEvents(registerListeners)
        .withPolicies(registerPolicies)
        .withSchedule(consoleRoutes)
        .withRouting(api: apiRoutes, web: webRoutes, health: '/up')
        .withMiddleware((middleware) {
          middleware.use(const <Middleware>[
            RequestIdMiddleware(),
            SecurityHeadersMiddleware(),
            BodyLimitsMiddleware(),
          ]);
        })
        .create();
''';

const String _migrationsRegistry = r'''
// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import '../database/migrations/m_0001_01_01_000000_create_users_table.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Migration> migrations = <Migration>[
  const CreateCacheTable(),
  const CreateJobsTable(),
  const CreatePersonalAccessTokensTable(),
  // <dartisan:entries>
  const CreateUsersTable(),
  // </dartisan:entries>
];
''';

const String _emptyMigrations = r'''
// Migration registry (explicit, AOT-friendly). See BLUEPRINT_V2 ADR-002.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Migration> migrations = <Migration>[
  // <dartisan:entries>
  // </dartisan:entries>
];
''';

const String _seedersRegistry = r'''
// Seeder registry (explicit, AOT-friendly). The first entry is the root seeder.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import '../database/seeders/database_seeder.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Seeder> seeders = <Seeder>[
  // <dartisan:entries>
  const DatabaseSeeder(),
  // </dartisan:entries>
];
''';

const String _emptySeeders = r'''
// Seeder registry (explicit, AOT-friendly). The first entry is the root seeder.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<Seeder> seeders = <Seeder>[
  // <dartisan:entries>
  // </dartisan:entries>
];
''';

const String _jobsRegistry = r'''
// Job registry (explicit, AOT-friendly): name → factory from JSON.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<JobDefinition> jobs = <JobDefinition>[
  // <dartisan:entries>
  // </dartisan:entries>
];
''';

const String _policiesRegistry = r'''
// Policy registry: model type → policy (Gate::policy).
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:{{ package }}/app/models/user.dart';
import 'package:{{ package }}/app/policies/user_policy.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
void registerPolicies(AuthorizationGate gate) {
  // <dartisan:entries>
  gate.policy<User>(const UserPolicy());
  // </dartisan:entries>
}
''';

const String _policiesRegistryEmpty = r'''
// Policy registry: model type → policy (Gate::policy).
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
void registerPolicies(AuthorizationGate gate) {
  // <dartisan:entries>
  // </dartisan:entries>
}
''';

const String _listenersRegistry = r'''
// Listener registry: event → listeners (EventServiceProvider::$listen).
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
void registerListeners(EventDispatcher events) {
  // <dartisan:entries>
  // </dartisan:entries>
}
''';

const String _commandsRegistry = r'''
// Console command registry (custom dartisan commands).
import 'package:dartisan_cli/dartisan_cli.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:*`; entries may also be added by hand.
final List<CommandFactory> commands = <CommandFactory>[
  // <dartisan:entries>
  // </dartisan:entries>
];
''';

const String _apiRoutes = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/http/controllers/auth_controller.dart';
import 'package:{{ package }}/app/http/controllers/ping_controller.dart';

/// API routes, mounted under `/api`.
void apiRoutes(Router router) {
  final auth = AuthController();

  router.get('/ping', PingController().ping).name('ping');
  router
      .post('/auth/register', auth.register)
      .name('auth.register')
      .middleware(const ['throttle:register']);
  router
      .post('/auth/login', auth.login)
      .name('auth.login')
      .middleware(const ['throttle:login']);
  router.group((router) {
    router.get('/auth/me', auth.me).name('auth.me');
    router.post('/auth/logout', auth.logout).name('auth.logout');
  }, middleware: const ['auth']);
}
''';

const String _apiRoutesMinimal = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/http/controllers/ping_controller.dart';

/// API routes, mounted under `/api`.
void apiRoutes(Router router) {
  router.get('/ping', PingController().ping).name('ping');
}
''';

const String _webRoutes = r'''
import 'package:daravel/daravel.dart';

/// Web routes, mounted at the root.
void webRoutes(Router router) {
  router.get('/', (_) => <String, Object?>{'app': Config.get<String>('app.name')});
}
''';

const String _consoleRoutes = r'''
import 'package:daravel/daravel.dart';

/// Scheduled tasks: run `dartisan schedule:run` every minute from cron, or
/// `dartisan schedule:work` in the foreground.
void consoleRoutes(Schedule schedule) {
  schedule
      .call(() async {
        final pruned = await Auth.tokenGuard().pruneExpired();
        Log.info('Pruned $pruned expired access token(s).');
      })
      .named('tokens:prune')
      .dailyAt('03:00')
      .withoutOverlapping();
}
''';

const String _consoleRoutesMinimal = r'''
import 'package:daravel/daravel.dart';

/// Scheduled tasks (`dartisan schedule:list`).
void consoleRoutes(Schedule schedule) {}
''';

const String _pingController = r'''
import 'package:daravel/daravel.dart';

final class PingController {
  /// `GET /api/ping`
  Object? ping(Request request) => <String, Object?>{
    'message': 'pong',
    'time': DateTime.now().toUtc().toIso8601String(),
  };
}
''';

const String _userModel = r'''
import 'package:daravel/daravel.dart';

final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password', 'remember_token'],
    casts: {
      'email_verified_at': Cast.dateTime,
      'created_at': Cast.dateTime,
      'updated_at': Cast.dateTime,
    },
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  // <dartisan:statics>
  static ModelQuery<User> query() => definition.query();
  static Future<User?> find(Object id) => query().find(id);
  static Future<User> findOrFail(Object id) => query().findOrFail(id);
  static Future<User> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<User>> all() => query().get();
  static ModelQuery<User> where(Object column, [Object? op, Object? value]) =>
      query().where(column, op, value);
  // </dartisan:statics>

  // <dartisan:accessors>
  int get id => getAttr('id');
  String get name => getAttr('name');
  set name(String value) => setAttr('name', value);
  String get email => getAttr('email');
  set email(String value) => setAttr('email', value);
  DateTime? get emailVerifiedAt => getAttr('email_verified_at');
  set emailVerifiedAt(DateTime? value) => setAttr('email_verified_at', value);
  String get password => getAttr('password');
  set password(String value) => setAttr('password', value);
  DateTime? get createdAt => getAttr('created_at');
  DateTime? get updatedAt => getAttr('updated_at');
  // </dartisan:accessors>
}
''';

const String _authController = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/http/requests/register_request.dart';
import 'package:{{ package }}/app/http/resources/user_resource.dart';
import 'package:{{ package }}/app/models/user.dart';

/// Token authentication (Sanctum-style personal access tokens).
final class AuthController {
  Future<Object?> register(Request request) async {
    final data = await FormRequest.run(const RegisterRequest(), request);
    // Hash before the transaction so the expensive work holds no locks.
    final password = await Hash.make(data.string('password'));
    // The user and its first token commit together, or not at all.
    final (user, token) = await DB.transaction(() async {
      final user = await User.create({
        'name': data.string('name'),
        'email': data.string('email'),
        'password': password,
      });
      return (user, await Auth.issueToken(user, 'api'));
    });
    return Response.created(<String, Object?>{
      'user': UserResource(user),
      'token': token.plainTextToken,
      'token_type': 'Bearer',
    });
  }

  Future<Object?> login(Request request) async {
    final data = await request.validate({
      'email': 'required|email',
      'password': 'required|string',
    });
    final user = await Auth.retrieveByCredentials<User>({
      'email': data.string('email'),
      'password': data.string('password'),
    });
    if (user == null) {
      throw ValidationException.withMessages({
        'email': ['These credentials do not match our records.'],
      });
    }
    final token = await Auth.issueToken(user, 'api');
    return <String, Object?>{
      'user': UserResource(user),
      'token': token.plainTextToken,
      'token_type': 'Bearer',
    };
  }

  Future<Object?> me(Request request) async =>
      UserResource((await request.user<User>())!);

  Future<Object?> logout(Request request) async {
    await Auth.tokenGuard().revokeCurrent();
    return Response.noContent();
  }
}
''';

const String _registerRequest = r'''
import 'package:daravel/daravel.dart';

final class RegisterRequest extends FormRequest {
  const RegisterRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'name': 'required|string|max:255',
    'email': 'required|email|max:255|unique:users,email',
    'password': [Rules.required(), Rules.password(min: 8), Rules.confirmed()],
  };
}
''';

const String _userResource = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/user.dart';

final class UserResource extends JsonResource<User> {
  UserResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'name': resource.name,
    'email': resource.email,
    'created_at': resource.createdAt,
  };
}
''';

const String _userPolicy = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/user.dart';

final class UserPolicy extends Policy<User> {
  const UserPolicy();

  @override
  Object? view(Authenticatable? user, User model) => true;

  @override
  Object? update(Authenticatable? user, User model) =>
      user is User && user.id == model.id;
}
''';

const String _usersMigration = r'''
import 'package:daravel/daravel.dart';

final class CreateUsersTable extends Migration {
  const CreateUsersTable();

  @override
  String get name => '0001_01_01_000000_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.timestamp('email_verified_at').nullable();
    table.string('password');
    table.rememberToken();
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}
''';

const String _userFactory = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/user.dart';

/// Users with a shared, pre-computed password hash (hashing is slow).
ModelFactory<User> userFactory({required String passwordHash, Faker? faker}) =>
    ModelFactory<User>(
      User.definition,
      (Faker f) => <String, Object?>{
        'name': f.name(),
        'email': f.email(),
        'password': passwordHash,
      },
      faker: faker,
    );
''';

const String _databaseSeeder = r'''
import 'package:daravel/daravel.dart';

import '../factories/user_factory.dart';

final class DatabaseSeeder extends Seeder {
  const DatabaseSeeder();

  @override
  Future<void> run() async {
    final password = await Hash.make('password');
    await userFactory(passwordHash: password).create({
      'name': 'Test User',
      'email': 'test@example.com',
    });
  }
}
''';

const String _authTest = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  test('register, me and logout', () async {
    final registered = (await client.post(
      '/api/auth/register',
      json: <String, Object?>{
        'name': 'Ana',
        'email': 'ana@example.com',
        'password': 'secret-123',
        'password_confirmation': 'secret-123',
      },
    )).assertCreated().assertJsonPath('user.email', 'ana@example.com');
    final token = (registered.json as Map<String, Object?>)['token'] as String;

    (await client.get('/api/auth/me')).assertUnauthorized();
    (await client.withToken(token).get('/api/auth/me'))
        .assertOk()
        .assertJsonPath('data.name', 'Ana');
    (await client.withToken(token).post('/api/auth/logout')).assertNoContent();
    (await client.withToken(token).get('/api/auth/me')).assertUnauthorized();
  });
}
''';

const String _architectureTest = r'''
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Architecture rules (`dart run bin/dartisan.dart lint` runs the same).
void main() {
  test('passes every Daravel lint rule', expectLintClean);
  test('keeps no mutable static state in lib/app', expectNoMutableStatics);
  test('registers every migration, seeder, job and command', expectRegistryComplete);
}
''';

const String _pingTest = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('GET /api/ping answers pong', () async {
    (await TestClient(app).get('/api/ping'))
        .assertOk()
        .assertJsonPath('message', 'pong');
  });
}
''';

const String _dartTestYaml = r'''
# Test tags (`dartisan test --conformance`, `dart test --tags conformance`).
tags:
  conformance:
  security:
''';

const String _conformanceTest = r'''
@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

/// Keeps this API on Laravel's wire format (validation errors, auth
/// messages, Sanctum tokens), so Laravel clients and a Laravel app sharing
/// the database keep working. Run with `dartisan test --conformance`.
void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  test('422 bodies are Laravel validation errors', () async {
    final res = await client.post('/api/auth/register', json: {});
    res.assertUnprocessable();
    expect(res.json, isLaravelValidationError());
  });

  test('401 and 404 use Laravel messages', () async {
    expect(
      (await client.get('/api/auth/me')).json,
      isLaravelErrorBody(LaravelContract.unauthenticated),
    );
    expect(
      (await client.get('/api/nope')).json,
      isLaravelErrorBody(LaravelContract.routeNotFound('api/nope')),
    );
  });

  test('tokens are Sanctum tokens', () async {
    final res = await client.post(
      '/api/auth/register',
      json: {
        'name': 'Ana',
        'email': 'ana@example.com',
        'password': 'secret-123',
        'password_confirmation': 'secret-123',
      },
    );
    res.assertCreated();
    expect(res.jsonMap['token'], matches(LaravelContract.sanctumPlainTextToken));
  });
}
''';

const String _dockerCompose = r'''
# Local stack: the app (built from Dockerfile) and Postgres 16.
#   docker compose up --build
services:
  app:
    build: .
    ports:
      - "8080:8080"
    environment:
      APP_KEY: "${APP_KEY:?set APP_KEY (dartisan key:generate)}"
      DB_CONNECTION: pgsql
      DB_HOST: db
      DB_PORT: "5432"
      DB_DATABASE: app
      DB_USERNAME: app
      DB_PASSWORD: secret
    depends_on:
      db:
        condition: service_healthy
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: app
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d app"]
      interval: 2s
      retries: 15
    volumes:
      - db:/var/lib/postgresql/data
volumes:
  db:
''';

const String _ciWorkflow = r'''
name: CI

on:
  push:
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
        with:
          sdk: stable
      - run: dart pub get
      - run: dart format --output=none --set-exit-if-changed .
      - run: dart analyze --fatal-infos
      - run: dart test
      - name: Laravel conformance
        run: dart run bin/dartisan.dart test --conformance
      - name: Native bundle
        run: dart build cli -t bin/server.dart -o build/server
''';
