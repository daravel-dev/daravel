import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show Encrypter, daravelVersion;
import 'package:path/path.dart' as p;

import 'generator.dart';
import 'mcp_server.dart';
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
      source.dependency('daravel_mysql'),
      source.dependency('dartisan_cli'),
    ].join('\n'),
    'devDependencies': source.dependency('daravel_test'),
    'overrides': source.needsOverrides
        ? [
            '',
            '# dartisan_cli and daravel_test depend on daravel and '
                'daravel_lints by name, and packages such as daravel_redis',
            '# on dartisan_cli; pin every framework package to the same '
                'source.',
            'dependency_overrides:',
            source.dependency('daravel'),
            source.dependency('daravel_lints'),
            source.dependency('daravel_mysql'),
            source.dependency('daravel_test'),
            source.dependency('dartisan_cli'),
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
    'bootstrap/models.dart': api ? _modelsRegistry : _emptyModels,
    'bootstrap/listeners.dart': _listenersRegistry,
    'bootstrap/commands.dart': _commandsRegistry,
    'routes/web.dart': _webRoutes,
    'lib/app/http/controllers/welcome_controller.dart': _welcomeController,
    'lib/resources/views/welcome_page.dart': _welcomePage,
    'routes/console.dart': api ? _consoleRoutes : _consoleRoutesMinimal,
    'lib/app/http/controllers/ping_controller.dart': _pingController,
    'storage/.gitignore': '*\n!.gitignore\n',
    'test/architecture_test.dart': _architectureTest,
    'test/feature/welcome_test.dart': _welcomeTest,
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
      'lib/app/http/requests/login_request.dart': _loginRequest,
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
        'mcp',
        negatable: false,
        help: 'Also write .mcp.json and AGENTS.md for AI coding agents.',
      )
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
    if (r['mcp'] as bool) {
      installMcp(directory);
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
  dartisan migrate${r['template'] == 'api' ? ' --seed' : ''}
  dartisan serve --watch
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
# Load shedding: 503 + Retry-After while a worker's event loop is this late
HTTP_MAX_QUEUE_DELAY=200ms
# HTTP_MAX_IN_FLIGHT=0
# Request body limit in bytes (50 MiB; 0 for none). BodyLimitsMiddleware
# tightens it to 1 MiB for JSON and forms.
# HTTP_MAX_BODY=52428800

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
dartisan migrate --seed
dartisan serve --watch           # hot reload, http://127.0.0.1:8000
dartisan test                    # = dart test
dartisan test --conformance      # Laravel wire-format contract
dartisan build --docker          # native bundle + Dockerfile
dartisan                         # every command, including your own
```

`dartisan` (`dart pub global activate dartisan_cli`) runs this project's own
CLI, `bin/dartisan.dart`, so `dart run bin/dartisan.dart <command>` works too.
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
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:{{ package }}/app/models/user.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'models.dart';
import 'policies.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. [env] overrides win over `.env`.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        // DB_CONNECTION=mysql or mariadb (sqlite and pgsql are built in).
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withModels(models)
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
import 'package:daravel_mysql/daravel_mysql.dart';

import '../routes/api.dart';
import '../routes/console.dart';
import '../routes/web.dart';
import 'jobs.dart';
import 'listeners.dart';
import 'migrations.dart';
import 'models.dart';
import 'policies.dart';
import 'seeders.dart';

/// Builds the (unbooted) application. [env] overrides win over `.env`.
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        // DB_CONNECTION=mysql or mariadb (sqlite and pgsql are built in).
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
        .withMigrations(migrations)
        .withSeeders(seeders)
        .withModels(models)
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
  // Framework-provided: Laravel Pennant's `features` (feature flags).
  const CreateFeaturesTable(),
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

const String _modelsRegistry = r'''
// Model registry (explicit, AOT-friendly): read by `dartisan model:show`
// and `dartisan mcp:serve`.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
import 'package:{{ package }}/app/models/user.dart';
// </dartisan:imports>

/// Maintained by `dartisan make:model`; entries may also be added by hand.
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  // <dartisan:entries>
  User.definition,
  // </dartisan:entries>
];
''';

const String _emptyModels = r'''
// Model registry (explicit, AOT-friendly): read by `dartisan model:show`
// and `dartisan mcp:serve`.
import 'package:daravel/daravel.dart';
// <dartisan:imports>
// </dartisan:imports>

/// Maintained by `dartisan make:model`; entries may also be added by hand.
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
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
import 'package:{{ package }}/app/http/requests/login_request.dart';
import 'package:{{ package }}/app/http/requests/register_request.dart';
import 'package:{{ package }}/app/http/resources/user_resource.dart';

/// API routes, mounted under `/api`. `.validates()` and `.returns()` also
/// document them (`openapi:generate`, `client:flutter`).
void apiRoutes(Router router) {
  final auth = AuthController();

  router.get('/ping', PingController().ping).name('ping');
  router
      .post('/auth/register', auth.register)
      .name('auth.register')
      .middleware(const ['throttle:register'])
      .validates(const RegisterRequest())
      .returns(AuthController.tokenSchema, name: 'AuthToken', shape: .raw);
  router
      .post('/auth/login', auth.login)
      .name('auth.login')
      .middleware(const ['throttle:login'])
      .validates(const LoginRequest())
      .returns(
        AuthController.tokenSchema,
        name: 'AuthToken',
        shape: .raw,
        status: 200,
      );
  router.group((router) {
    router
        .get('/auth/me', auth.me)
        .name('auth.me')
        .returns(UserResource.schema, name: 'User');
    router
        .post('/auth/logout', auth.logout)
        .name('auth.logout')
        .returns(const <String, Object?>{}, status: 204);
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
import 'package:{{ package }}/app/http/controllers/welcome_controller.dart';

/// Web routes (HTML), mounted at the root by `bootstrap/app.dart`.
void webRoutes(Router router) {
  final welcome = WelcomeController();

  router.get('/', welcome.index).name('welcome');
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
import 'package:{{ package }}/app/http/resources/user_resource.dart';
import 'package:{{ package }}/app/models/user.dart';

/// Token authentication (Sanctum-style personal access tokens). The routes
/// validate the input (`.validates(...)` in `routes/api.dart`).
final class AuthController {
  /// JSON Schema of the register and login responses, for `.returns(...)`.
  static const Map<String, Object?> tokenSchema = {
    'title': 'AuthToken',
    'type': 'object',
    'required': ['user', 'token', 'token_type'],
    'properties': {
      'user': UserResource.schema,
      'token': {'type': 'string'},
      'token_type': {
        'type': 'string',
        'enum': ['Bearer'],
      },
    },
  };

  Future<Object?> register(Request request) async {
    final data = request.validated();
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
    final data = request.validated();
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

const String _loginRequest = r'''
import 'package:daravel/daravel.dart';

final class LoginRequest extends FormRequest {
  const LoginRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'email': 'required|email',
    'password': 'required|string',
  };
}
''';

const String _userResource = r'''
import 'package:daravel/daravel.dart';
import 'package:{{ package }}/app/models/user.dart';

final class UserResource extends JsonResource<User> {
  UserResource(super.resource);

  /// JSON Schema of [toArray], for `.returns(...)`.
  static const Map<String, Object?> schema = {
    'title': 'User',
    'type': 'object',
    'required': ['id', 'name', 'email'],
    'properties': {
      'id': {'type': 'integer'},
      'name': {'type': 'string'},
      'email': {'type': 'string', 'format': 'email'},
      'created_at': {
        'type': ['string', 'null'],
        'format': 'date-time',
      },
    },
  };

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

/// Same as `apps/daravel_starter/lib/resources/views/welcome_page.dart`
/// (kept identical by `test/s12_test.dart`).
const String _welcomePage = r"""
import 'dart:convert';

import 'package:daravel/daravel.dart'
    show daravelFaviconDataUri, daravelLogoDataUri;

/// Renders the welcome landing page served at `/`.
///
/// Views are plain Dart until the Blade-compatible compiler lands (ADR-018).
/// Every dynamic value passes through [escape] so the page is XSS-safe.
String welcomePage({
  required String appName,
  required String environment,
  required String dartVersion,
  required String frameworkVersion,
  required String requestId,
}) {
  final name = escape(appName);
  return '''
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name</title>
<link rel="icon" type="image/png" href="$daravelFaviconDataUri">
<style>
  :root {
    --bg: #0b0d12; --panel: #12151c; --panel-2: #171b24; --line: #232936;
    --text: #e6e8ee; --muted: #9aa3b5; --accent: #ff2d20; --accent-2: #ff6a5c;
    --ok: #22c55e; --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg: #f7f7f8; --panel: #ffffff; --panel-2: #f1f2f5; --line: #e4e6ea;
            --text: #16181d; --muted: #5f6675; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
         font: 16px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  .glow { position: fixed; inset: -40% -20% auto; height: 70vh; pointer-events: none;
          background: radial-gradient(60% 60% at 50% 40%, rgba(255,45,32,.18), transparent 70%); }
  main { position: relative; max-width: 1040px; margin: 0 auto; padding: 72px 24px 48px; }
  header { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  .brand { display: flex; align-items: center; gap: 12px; font-weight: 700; font-size: 20px; letter-spacing: .2px; }
  .mark { width: 40px; height: 40px; display: grid; place-items: center; }
  .mark img { width: 40px; height: 40px; border-radius: 9px; box-shadow: 0 6px 18px rgba(1,117,194,.25); }
  .env { font-family: var(--mono); font-size: 12px; color: var(--muted); border: 1px solid var(--line);
         border-radius: 999px; padding: 6px 12px; display: inline-flex; gap: 8px; align-items: center; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); box-shadow: 0 0 0 4px rgba(34,197,94,.15); }
  h1 { font-size: clamp(36px, 6vw, 60px); line-height: 1.05; margin: 64px 0 16px; letter-spacing: -.02em; }
  h1 span { background: linear-gradient(90deg, var(--accent), var(--accent-2)); -webkit-background-clip: text; background-clip: text; color: transparent; }
  .lead { color: var(--muted); font-size: 18px; max-width: 640px; margin: 0 0 40px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
  a.card { display: block; text-decoration: none; color: inherit; background: var(--panel);
           border: 1px solid var(--line); border-radius: 16px; padding: 22px;
           transition: transform .15s ease, border-color .15s ease; }
  a.card:hover { transform: translateY(-2px); border-color: var(--accent); }
  div.card { background: var(--panel); border: 1px solid var(--line); border-radius: 16px; padding: 22px; }
  .card a { color: inherit; }
  .card h2 { font-size: 17px; margin: 0 0 6px; }
  .card p { margin: 0; color: var(--muted); font-size: 14px; }
  .card code { font-family: var(--mono); font-size: 13px; color: var(--accent-2); }
  .term { margin-top: 32px; background: var(--panel-2); border: 1px solid var(--line); border-radius: 16px;
          padding: 18px 22px; font-family: var(--mono); font-size: 13.5px; overflow-x: auto; }
  .term .c { color: var(--muted); }
  footer { margin-top: 40px; display: flex; flex-wrap: wrap; gap: 8px 24px; color: var(--muted);
           font-size: 13px; font-family: var(--mono); }
</style>
</head>
<body>
<div class="glow"></div>
<main>
  <header>
    <div class="brand"><div class="mark"><img src="$daravelLogoDataUri" alt="Daravel logo" width="40" height="40"></div>$name</div>
    <div class="env"><span class="dot"></span>${escape(environment)} &middot; request ${escape(requestId)}</div>
  </header>

  <h1>The Laravel experience,<br><span>compiled to native Dart.</span></h1>
  <p class="lead">Your application is up and serving from a single AOT binary. Start by exploring the
  API, reading the documentation, or scaffolding your first endpoint with <code>dartisan</code>.</p>

  <div class="grid">
    <div class="card">
      <h2>Try the API</h2>
      <p><a href="/api/ping"><code>GET /api/ping</code></a> &middot; <a href="/up"><code>GET /up</code></a> &middot;
      <a href="/up/ready"><code>GET /up/ready</code></a>: JSON responses with request ids.
      Locally, <a href="/docs/api">/docs/api</a> lists every route with its schemas and lets you send requests.</p>
    </div>
    <a class="card" href="https://github.com/daravel-dev/daravel/blob/main/docs/guide/index.md">
      <h2>Documentation</h2>
      <p>Guides for routing, validation, the ORM, auth, queues, testing and deployment.</p>
    </a>
    <a class="card" href="https://github.com/daravel-dev/daravel/blob/main/docs/guide/parity.md">
      <h2>Laravel &harr; Daravel</h2>
      <p>Side-by-side comparison of routing, validation, migrations and tests.</p>
    </a>
    <a class="card" href="https://github.com/daravel-dev/daravel">
      <h2>Source on GitHub</h2>
      <p>Framework core, <code>dartisan</code> CLI, testing toolkit and this starter.</p>
    </a>
  </div>

  <div class="term">
<span class="c"># next steps</span><br>
dartisan route:list<br>
dartisan migrate --seed<br>
dartisan test<br>
dartisan build<span class="c"> &nbsp;# ship a native AOT bundle</span>
  </div>

  <footer>
    <span>Daravel ${escape(frameworkVersion)}</span>
    <span>Dart ${escape(dartVersion)}</span>
    <span>APP_ENV=${escape(environment)}</span>
  </footer>
</main>
</body>
</html>
''';
}

/// HTML-escapes [value] (same character set as Laravel's `e()` helper).
String escape(String value) =>
    const HtmlEscape(HtmlEscapeMode.element)
        .convert(value)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
""";

const String _welcomeController = r'''
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:{{ package }}/resources/views/welcome_page.dart';

/// Serves the welcome landing page at `/` (Laravel's `welcome.blade.php`).
///
/// Browsers get the HTML page; clients asking for JSON (`Accept:
/// application/json`) get a short status document instead.
final class WelcomeController {
  static const String frameworkVersion = daravelVersion;

  Future<Object?> index(Request request) async {
    final app = Config.section<AppConfig>();
    if (request.expectsJson) {
      return <String, Object?>{
        'app': app.name,
        'env': app.env,
        'daravel': frameworkVersion,
      };
    }
    return Response.html(
      welcomePage(
        appName: app.name,
        environment: app.env,
        dartVersion: Platform.version.split(' ').first,
        frameworkVersion: frameworkVersion,
        requestId: request.id,
      ),
    );
  }
}
''';

const String _welcomeTest = r'''
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

  test('GET / renders the welcome page for browsers', () async {
    (await TestClient(app).get('/', headers: {'accept': 'text/html'}))
        .assertOk()
        .assertHeader('content-type', 'text/html; charset=utf-8')
        .assertSee('compiled to native Dart');
  });

  test('GET / answers JSON clients with a status document', () async {
    (await TestClient(app).get('/'))
        .assertOk()
        .assertJsonPath('daravel', daravelVersion);
  });
}
''';
