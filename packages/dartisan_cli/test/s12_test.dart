import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProjectPaths paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dartisan_s12_');
    await File(p.join(root.path, 'pubspec.yaml')).writeAsString('name: demo\n');
    await Directory(p.join(root.path, 'bootstrap')).create();
    paths = ProjectPaths.locate(root.path);
  });

  tearDown(() => root.delete(recursive: true));

  group('stubs', () {
    test('renderStub fills known placeholders and keeps unknown ones', () {
      expect(
        renderStub('a {{ x }} {{y}} {{ z }}', {'x': '1', 'y': '2'}),
        'a 1 2 {{ z }}',
      );
    });

    test('every built-in stub renders without leftover placeholders', () {
      const values = {
        'class': 'Thing',
        'table': 'things',
        'softDeletes': '',
        'name': 'n',
        'model': 'Thing',
        'modelFile': 'thing',
        'function': 'thingFactory',
        'package': 'demo',
        'param': 'thing',
        'resource': 'things',
        'jobName': 'thing',
        'event': 'Happened',
        'eventFile': 'happened',
        'ruleName': 'thing',
        'signature': 'app:thing',
        'description': 'thing',
      };
      for (final entry in builtInStubs.entries) {
        expect(
          renderStub(entry.value, values),
          isNot(contains('{{')),
          reason: entry.key,
        );
      }
    });

    test('published stubs override the built-in templates', () {
      final gen = Generator(paths);
      final published = gen.publishStubs();
      expect(published.length, builtInStubs.length);
      expect(File(p.join(paths.stubs, 'model.stub')).existsSync(), isTrue);
      File(p.join(paths.stubs, 'event.stub'))
          .writeAsStringSync('// custom\nfinal class {{ class }} {}\n');
      gen.event('Shipped');
      expect(
        File(p.join(paths.events, 'shipped.dart')).readAsStringSync(),
        '// custom\nfinal class Shipped {}\n',
      );
      expect(Generator(paths).publishStubs().every((f) => f.skipped), isTrue);
    });
  });

  group('generators and registries', () {
    test('policy, listener and command patch function/list registries', () {
      final gen = Generator(paths)
        ..policy('Post', model: 'Post')
        ..policy('Comment', model: 'Comment')
        ..listener('SendNotice', event: 'OrderShipped')
        ..command('SendReports')
        ..command('Prune', signature: 'tokens:prune');
      final policies = File(paths.policiesRegistry).readAsStringSync();
      expect(
        policies,
        contains('void registerPolicies(AuthorizationGate gate) {'),
      );
      expect(policies, contains("import 'package:demo/app/models/post.dart';"));
      expect(
        policies,
        contains("import 'package:demo/app/policies/post_policy.dart';"),
      );
      expect(
        policies,
        contains(
          '  gate.policy<Post>(const PostPolicy());\n  gate.policy<Comment>(const CommentPolicy());\n  // </dartisan:entries>',
        ),
      );
      final listeners = File(paths.listenersRegistry).readAsStringSync();
      expect(
        listeners,
        contains('events.listen<OrderShipped>(const SendNotice().handle);'),
      );
      final commands = File(paths.commandsRegistry).readAsStringSync();
      expect(
        commands,
        contains("import 'package:dartisan_cli/dartisan_cli.dart';"),
      );
      expect(
        commands,
        contains('  SendReportsCommand.new,\n  PruneCommand.new,'),
      );
      expect(
        File(p.join(paths.commands, 'prune_command.dart')).readAsStringSync(),
        contains("String get name => 'tokens:prune';"),
      );
      expect(
        File(p.join(paths.commands, 'send_reports_command.dart'))
            .readAsStringSync(),
        contains("'app:send-reports'"),
      );
      expect(gen.hints, isEmpty);
    });

    test('resource picks the model stub when the model exists; hints are collected', () {
      final gen = Generator(paths)
        ..model('Post')
        ..resource('Post')
        ..resource('Stats')
        ..observer('Audit', model: 'Post')
        ..provider('Billing')
        ..rule('Uppercase')
        ..test('PostApi')
        ..test('Math', unit: true);
      expect(
        File(p.join(paths.resources, 'post_resource.dart')).readAsStringSync(),
        contains('extends JsonResource<Post>'),
      );
      expect(
        File(p.join(paths.resources, 'stats_resource.dart')).readAsStringSync(),
        contains('JsonResource<Map<String, Object?>>'),
      );
      expect(
        File(p.join(paths.observers, 'audit_observer.dart')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(paths.providers, 'billing_service_provider.dart'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(paths.featureTests, 'post_api_test.dart')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(paths.unitTests, 'math_test.dart')).existsSync(),
        isTrue,
      );
      expect(gen.hints, hasLength(2));
    });

    test('registry patcher keeps the closing marker indentation', () {
      const source =
          'final x = [\n  // <dartisan:entries>\n  // </dartisan:entries>\n];\n// <dartisan:imports>\n// </dartisan:imports>\n';
      final patched = RegistryPatcher.patch(
        source,
        importLine: "import 'a.dart';",
        entryLine: '  a,',
      )!;
      expect(
        patched,
        contains('  // <dartisan:entries>\n  a,\n  // </dartisan:entries>'),
      );
    });
  });

  group('openapi', () {
    test('documents paths, params, security and error responses', () {
      final router = Router()
        ..get(
          '/api/users/{id}',
          (_) => null,
        ).name('users.show').whereNumber('id').middleware(['auth'])
        ..patch(
          '/api/posts/{post}',
          (_) => null,
        ).middleware(['auth:token', 'can:update,post', 'throttle:60,1'])
        ..get('/', (_) => null);
      final doc = buildOpenApi(
        router.routes,
        title: 'Demo',
        serverUrl: 'https://x.test',
      );
      expect(doc['openapi'], '3.1.0');
      final paths = doc['paths']! as Map<String, Object?>;
      final show =
          (paths['/api/users/{id}']! as Map)['get'] as Map<String, Object?>;
      expect(show['operationId'], 'users.show');
      expect(show['tags'], ['users']);
      expect(((show['parameters']! as List).single as Map)['schema'], {
        'type': 'integer',
      });
      expect(show['security'], [
        {'bearerAuth': <String>[]},
      ]);
      expect(
        (show['responses']! as Map).keys,
        containsAll(['200', '401', '404']),
      );
      final patch =
          (paths['/api/posts/{post}']! as Map)['patch'] as Map<String, Object?>;
      expect(
        (patch['responses']! as Map).keys,
        containsAll(['200', '401', '403', '404', '422', '429']),
      );
      expect(patch['operationId'], 'patchApiPostsPost');
      expect(((paths['/']! as Map)['get'] as Map)['operationId'], 'getRoot');
      expect(((doc['components']! as Map)['securitySchemes'] as Map).keys, [
        'bearerAuth',
      ]);
      expect(jsonEncode(doc), isNot(contains('"head"')));
    });

    test('declared rules and responses become schemas', () {
      const post = {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'title': {'type': 'string'},
        },
      };
      final router = Router()
        ..post('/api/posts', (_) => null)
            .rules(const {'title': 'required|string|max:120'})
            .returns(post, name: 'Post')
            .action('PostController@store')
        ..get('/api/posts', (_) => null)
            .rules(const {'q': 'sometimes|string', 'page': 'integer|min:1'})
            .returns(post, name: 'Post', shape: ResponseShape.paginated);
      final doc = buildOpenApi(router.routes);
      final paths = (doc['paths']! as Map)['/api/posts'] as Map;

      final store = paths['post'] as Map<String, Object?>;
      final body =
          (((store['requestBody']! as Map)['content']
                      as Map)['application/json']
                  as Map)['schema']
              as Map;
      expect(body['required'], ['title']);
      expect((body['properties'] as Map)['title'], {
        'type': 'string',
        'maxLength': 120,
      });
      expect(store['x-daravel-action'], 'PostController@store');
      final created = (store['responses']! as Map)['201'] as Map;
      final createdSchema =
          ((created['content'] as Map)['application/json'] as Map)['schema']
              as Map;
      expect(createdSchema['properties'], {
        'data': {r'$ref': '#/components/schemas/Post'},
      });
      expect((store['responses']! as Map).keys, contains('422'));

      final index = paths['get'] as Map<String, Object?>;
      final query = [
        for (final p in index['parameters']! as List)
          if ((p as Map)['in'] == 'query') p['name'],
      ];
      expect(query, ['q', 'page']);
      final page =
          ((((index['responses']! as Map)['200'] as Map)['content']
                      as Map)['application/json']
                  as Map)['schema']
              as Map;
      expect((page['properties'] as Map).keys, ['data', 'links', 'meta']);
      expect(
        (((page['properties'] as Map)['meta'] as Map)['properties'] as Map)
            .keys,
        containsAll(['current_page', 'last_page', 'links', 'total']),
      );
      expect(((doc['components']! as Map)['schemas'] as Map).keys, ['Post']);
    });
  });

  group('model:sync', () {
    const source = '''
final class Post extends Model with AuthenticatableModel {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    casts: {'published_at': Cast.dateTime, 'is_draft': Cast.boolean},
  );

  // <dartisan:accessors>
  int get id => getAttr('id');
  // </dartisan:accessors>

  String get custom => 'kept';
}
''';

    test('parses the model and maps column types with casts', () {
      final model = ModelSource.parse(source)!;
      expect(model.className, 'Post');
      expect(model.table, 'posts');
      expect(model.casts, {'published_at': 'dateTime', 'is_draft': 'boolean'});
      expect(model.authenticatable, isTrue);
      final plan = planAccessors(model, const [
        ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
        ColumnInfo(name: 'title', type: 'VARCHAR', nullable: false),
        ColumnInfo(name: 'body', type: 'TEXT', nullable: true),
        ColumnInfo(name: 'views', type: 'BIGINT', nullable: false),
        ColumnInfo(name: 'score', type: 'REAL', nullable: true),
        ColumnInfo(name: 'published_at', type: 'TIMESTAMP', nullable: true),
        ColumnInfo(name: 'is_draft', type: 'BOOLEAN', nullable: false),
        ColumnInfo(name: 'archived', type: 'BOOLEAN', nullable: false),
        ColumnInfo(name: 'meta', type: 'JSON', nullable: true),
        ColumnInfo(name: 'remember_token', type: 'VARCHAR', nullable: true),
        ColumnInfo(name: 'created_at', type: 'TIMESTAMP', nullable: true),
      ]);
      expect(
        plan.lines,
        containsAll([
          "  int get id => getAttr('id');",
          "  String get title => getAttr('title');",
          "  set title(String value) => setAttr('title', value);",
          "  String? get body => getAttr('body');",
          "  int get views => getAttr('views');",
          "  double? get score => getAttr('score');",
          "  DateTime? get publishedAt => getAttr('published_at');",
          "  bool get isDraft => getAttr('is_draft');",
          "  Object? get archived => getAttr('archived');",
          "  Object? get meta => getAttr('meta');",
          "  String? get createdAt => getAttr('created_at');",
        ]),
      );
      expect(plan.lines, isNot(contains(contains('set id('))));
      expect(plan.lines, isNot(contains(contains('set createdAt('))));
      expect(plan.lines, isNot(contains(contains('rememberToken'))));
      expect(
        plan.warnings.join('\n'),
        allOf(
          contains('remember_token'),
          contains('Cast.boolean'),
          contains('Cast.json'),
          contains('Cast.dateTime'),
        ),
      );
    });

    test('replaceAccessors only touches the marked region', () {
      final updated = replaceAccessors(source, [
        "  String get title => getAttr('title');",
      ])!;
      expect(
        updated,
        contains(
          "  // <dartisan:accessors>\n  String get title => getAttr('title');\n  // </dartisan:accessors>",
        ),
      );
      expect(updated, contains("String get custom => 'kept';"));
      expect(updated, isNot(contains("int get id")));
      expect(replaceAccessors('class X {}', const []), isNull);
    });
  });

  group('project helpers', () {
    test('env helpers set and parse keys', () {
      expect(
        setEnvValue('A=1\nAPP_KEY=\nB=2\n', 'APP_KEY', 'base64:x'),
        'A=1\nAPP_KEY=base64:x\nB=2\n',
      );
      expect(setEnvValue('A=1', 'APP_KEY', 'k'), 'A=1\nAPP_KEY=k\n');
      expect(parseEnvKeys('# c\nA=1\n B = two\nnot a line\n'), {
        'A': '1',
        'B': 'two',
      });
    });

    test('hot reload vs restart decision', () {
      expect(
        actionFor(['lib/app/http/controllers/x.dart']),
        ReloadAction.hotReload,
      );
      expect(
        actionFor(['bin/server.dart', 'lib/a.dart']),
        ReloadAction.hotReload,
      );
      for (final path in [
        'routes/api.dart',
        r'bootstrap\app.dart',
        '.env',
        'database/migrations/m.dart',
        'pubspec.yaml',
      ]) {
        expect(
          actionFor(['lib/a.dart', path]),
          ReloadAction.restart,
          reason: path,
        );
      }
    });

    test('Dockerfile builds both binaries on a slim runtime', () {
      final docker = dockerfileTemplate();
      expect(docker, contains('FROM dart:stable AS build'));
      expect(docker, contains('dart build cli -t bin/server.dart'));
      expect(docker, isNot(contains('libsqlite3-0')));
      expect(docker, contains('CMD ["/app/bin/server"]'));
      expect(docker, contains('USER daravel'));
    });

    test('the starter Dockerfile shares the runtime stage', () {
      String runtime(String dockerfile) =>
          dockerfile.substring(dockerfile.indexOf('FROM debian')).trim();
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final starter = File(
        p.join(repo, 'apps', 'daravel_starter', 'Dockerfile'),
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(runtime(starter), runtime(dockerfileTemplate()));
      expect(dockerignoreTemplate, contains('!.env.encrypted'));
    });
  });

  group('new project', () {
    test('api template renders every placeholder and a valid APP_KEY', () {
      final files = newProjectFiles(
        package: 'blog',
        appName: 'Blog',
        source: const PathSource('/repo'),
      );
      for (final entry in files.entries) {
        expect(entry.value, isNot(contains('{{')), reason: entry.key);
      }
      expect(
        files.keys,
        containsAll([
          'pubspec.yaml',
          'bin/server.dart',
          'bin/dartisan.dart',
          'bootstrap/app.dart',
          'bootstrap/policies.dart',
          'bootstrap/listeners.dart',
          'bootstrap/commands.dart',
          'lib/app/models/user.dart',
          'test/feature/auth_test.dart',
          'Dockerfile',
          '.env',
        ]),
      );
      expect(
        files['pubspec.yaml'],
        matches(RegExp(r'path: ([A-Za-z]:)?/repo/packages/daravel')),
      );
      expect(files['pubspec.yaml'], contains('dependency_overrides:'));
      final key = parseEnvKeys(files['.env']!)['APP_KEY']!;
      expect(Encrypter.parseKey(key), hasLength(32));
      expect(parseEnvKeys(files['.env.example']!)['APP_KEY'], '');
    });

    test('minimal template and git source', () {
      final files = newProjectFiles(
        package: 'tiny',
        appName: 'Tiny',
        template: 'minimal',
        source: const GitSource(ref: 'v1'),
      );
      expect(files.containsKey('lib/app/models/user.dart'), isFalse);
      expect(files['pubspec.yaml'], contains('ref: v1'));
      expect(files['pubspec.yaml'], contains('path: packages/dartisan_cli'));
      expect(
        () => newProjectFiles(
          package: 'x',
          appName: 'X',
          template: 'web',
          source: const GitSource(),
        ),
        throwsArgumentError,
      );
    });

    for (final template in ['api', 'minimal']) {
      test(
        '$template project resolves, analyzes and passes its tests (e2e)',
        () async {
          final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
          final target = p.join(root.path, template);
          final runner = GlobalDartisanRunner();
          expect(
            await runner.execute([
              'new',
              target,
              '--path=$repo',
              '--template=$template',
            ]),
            0,
          );
          final analyze = await Process.run(dartExecutable(), const [
            'analyze',
            '--fatal-infos',
          ], workingDirectory: target);
          expect(analyze.exitCode, 0, reason: '${analyze.stdout}');
          final test = await Process.run(dartExecutable(), const [
            'test',
          ], workingDirectory: target);
          expect(test.exitCode, 0, reason: '${test.stdout}');
        },
        skip: Platform.environment['DARAVEL_E2E'] == '1'
            ? false
            : 'set DARAVEL_E2E=1 to run (pub get + analyze + test, ~1 min)',
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }
  });

  group('dartisan test', () {
    test('maps flags to dart test arguments', () {
      expect(TestCommand.dartArgs(), ['test']);
      expect(TestCommand.dartArgs(conformance: true), [
        'test',
        '--tags',
        'conformance',
      ]);
      expect(TestCommand.dartArgs(coverage: true, rest: ['test/unit']), [
        'test',
        '--coverage=coverage',
        'test/unit',
      ]);
    });
  });

  group('queue:pause / queue:continue', () {
    test('parse Laravel-style [connection:]queue targets', () {
      expect(parseQueueTarget(null), (null, 'default'));
      expect(parseQueueTarget('emails'), (null, 'emails'));
      expect(parseQueueTarget('database:emails'), ('database', 'emails'));
    });

    test('are registered', () {
      final runner = DartisanRunner(
        Application.configure(basePath: '.').create,
      );
      expect(
        runner.commands.keys,
        containsAll(['queue:pause', 'queue:continue']),
      );
    });
  });

  group('global dartisan inside a project (UX review #6)', () {
    test('delegates everything except creating a project', () {
      for (final args in [
        <String>[],
        ['--help'],
        ['help'],
        ['help', 'migrate'],
        ['migrate', '--seed'],
        ['migrate', '--help'],
        ['serve', '--watch'],
        ['make:model', 'Post'],
      ]) {
        expect(
          GlobalDartisanRunner.delegates(args, inProject: true),
          isTrue,
          reason: '$args',
        );
      }
      for (final args in [
        ['new', 'blog'],
        ['help', 'new'],
        ['new', '--help'],
      ]) {
        expect(
          GlobalDartisanRunner.delegates(args, inProject: true),
          isFalse,
          reason: '$args',
        );
      }
      expect(
        GlobalDartisanRunner.delegates(['migrate'], inProject: false),
        isFalse,
      );
    });
  });

  group('welcome page template', () {
    test('new projects get the starter landing page, verbatim', () {
      final files = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const GitSource(),
      );
      final repo = p.normalize(p.join(Directory.current.path, '..', '..'));
      final starter = File(
        p.join(
          repo,
          'apps',
          'daravel_starter',
          'lib',
          'resources',
          'views',
          'welcome_page.dart',
        ),
      ).readAsStringSync();
      expect(files['lib/resources/views/welcome_page.dart'], starter);
      expect(
        files['lib/app/http/controllers/welcome_controller.dart'],
        contains('package:shop/resources/views/welcome_page.dart'),
      );
      expect(files['routes/web.dart'], contains('WelcomeController'));
    });
  });

  group('framework sources', () {
    test('pub.dev source writes a plain pubspec without overrides', () {
      final pubspec = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const PubHostedSource(),
      )['pubspec.yaml']!;
      expect(pubspec, contains('  daravel: ^$daravelVersion'));
      expect(pubspec, contains('  dartisan_cli: ^$daravelVersion'));
      expect(pubspec, contains('  daravel_test: ^$daravelVersion'));
      expect(pubspec, isNot(contains('dependency_overrides')));
    });

    test('git and path sources pin every package with overrides', () {
      for (final source in [const GitSource(), const PathSource('/repo')]) {
        final pubspec = newProjectFiles(
          package: 'shop',
          appName: 'Shop',
          source: source,
        )['pubspec.yaml']!;
        expect(pubspec, contains('dependency_overrides:'));
      }
      expect(
        newProjectFiles(
          package: 'shop',
          appName: 'Shop',
          source: const GitSource(),
        )['pubspec.yaml'],
        contains('url: https://github.com/daravel-dev/daravel.git'),
      );
    });
  });

  group('templates (S14)', () {
    test('api ships conformance, compose and CI; minimal ships CI', () {
      final api = newProjectFiles(
        package: 'shop',
        appName: 'Shop',
        source: const GitSource(),
      );
      expect(
        api.keys,
        containsAll(<String>[
          'dart_test.yaml',
          '.github/workflows/ci.yml',
          'test/conformance/api_contract_test.dart',
          'docker-compose.yml',
        ]),
      );
      expect(api['routes/api.dart'], contains('throttle:register'));
      final minimal = newProjectFiles(
        package: 'tiny',
        appName: 'Tiny',
        source: const GitSource(),
        template: 'minimal',
      );
      expect(minimal.keys, contains('.github/workflows/ci.yml'));
      expect(minimal.keys, isNot(contains('docker-compose.yml')));
    });
  });
}
