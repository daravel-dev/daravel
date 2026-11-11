import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/names_sync.dart';
import 'package:dartisan_cli/src/project_commands.dart';
import 'package:dartisan_cli/src/region_format.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dartisan names:sync` (W9.6): the registered names as constants and URL
/// builders, read from an application booted for inspection.
void main() {
  const names = (
    routes: [
      (name: 'posts.show', methods: ['GET'], path: '/api/posts/{post}'),
      (name: 'posts.index', methods: ['GET'], path: '/api/posts/{page?}'),
      (name: 'files', methods: ['GET'], path: '/files/{path*}'),
      (name: 'home', methods: ['GET'], path: '/'),
      (name: 'home-page', methods: ['GET'], path: '/home'),
    ],
    abilities: ['update-post', 'update'],
    policies: true,
    rateLimiters: ['login', 'api'],
    guards: ['token', 'jwt'],
    disks: ['local', 'public'],
    connections: ['sqlite'],
  );

  test('names become Dart names; a clash gets a number and a warning', () {
    final warnings = <String>[];
    final taken = <String>{};
    expect(dartName('posts.show', taken, warnings), 'postsShow');
    expect(dartName('update-post', taken, warnings), 'updatePost');
    expect(dartName('1st', taken, warnings), 'n1st');
    expect(dartName('class', taken, warnings), 'className');
    expect(dartName('posts_show', taken, warnings), 'postsShow2');
    expect(warnings.single, contains('[posts_show] is written as postsShow2'));
  });

  test('route parameters: required, optional and wildcard', () {
    expect(routeParams('/a/{post}/{slug?}/{rest*}'), [
      (name: 'post', optional: false),
      (name: 'slug', optional: true),
      (name: 'rest', optional: false),
    ]);
  });

  test('the region: builders, constants and the policy abilities once', () {
    final code = namesRegion(names).code;
    expect(code, contains('static String postsShow({'));
    expect(code, contains('    required Object post,'));
    expect(code, contains('    Object? page,'));
    expect(code, contains("      'page': ?page,"));
    expect(code, contains("static const updatePost = Ability('update-post');"));
    // `update` is defined and a policy ability: written once.
    expect(RegExp(r"Ability\('update'\)").allMatches(code), hasLength(1));
    expect(
      code,
      contains("static const forceDelete = Ability('forceDelete');"),
    );
    expect(code, contains("static const login = 'login';"));
  });

  test('the synced file compiles and types its use', () async {
    final synced = syncNamesSource(
      null,
      names,
      formatter: RegionFormatter(),
    ).source;
    final dir = Directory(p.normalize(p.absolute('.dart_tool/names_sync')));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'names.dart')).writeAsStringSync(synced);
    File(p.join(dir.path, 'use.dart')).writeAsStringSync('''
import 'package:daravel/daravel.dart';

import 'names.dart';

Future<void> use() async {
  final String show = Routes.postsShow(post: 7, query: {'tab': 'comments'});
  final String index = Routes.postsIndex();
  final String files = Routes.files(path: 'a/b');
  final bool may = await Gate.allows(Abilities.updatePost);
  final String limit = RateLimiters.login;
  print([show, index, files, may, limit, Guards.token, Disks.public,
      Connections.sqlite, RouteNames.home, Routes.homePage()]);
}
''');
    File(p.join(dir.path, 'missing.dart')).writeAsStringSync('''
import 'names.dart';

final String missing = Routes.postsShow();
''');
    final collection = AnalysisContextCollection(includedPaths: [dir.path]);
    Future<List<String>> diagnostics(String name) async {
      final path = p.join(dir.path, name);
      final result = await collection
          .contextFor(path)
          .currentSession
          .getErrors(path);
      return result is ErrorsResult
          ? [for (final d in result.diagnostics) d.diagnosticCode.lowerCaseName]
          : ['not analyzed'];
    }

    expect(await diagnostics('names.dart'), isEmpty, reason: synced);
    expect(await diagnostics('use.dart'), isEmpty);
    expect(await diagnostics('missing.dart'), ['missing_required_argument']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('the command', () {
    late Directory project;

    setUp(() {
      project = Directory.systemTemp.createTempSync('names_sync_');
      File(p.join(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: shop\nenvironment:\n  sdk: ^3.13.0\n');
      Directory(p.join(project.path, 'bootstrap')).createSync();
    });

    tearDown(() => project.deleteSync(recursive: true));

    Application Function() app({bool extra = false}) =>
        () => Application.configure(basePath: project.path)
            .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
            .withDatabaseDriver(
              'sqlite',
              (name, config) => throw StateError('names:sync connected'),
            )
            .withPolicies((gate) => gate.define('update-post', (u, a) => true))
            .withRateLimits(
              (limiter) => limiter.define('login', (_) => Limit.perMinute(5)),
            )
            .withRouting(
              api: (r) {
                r.get('/posts/{post}', (_) async => {}).name('posts.show');
                if (extra) {
                  r.get('/tags', (_) async => {}).name('tags.index');
                }
              },
            )
            .create();

    Future<int?> run(
      Application Function() createApp, [
      List<String> args = const [],
    ]) => (CommandRunner<int>(
      'dartisan',
      'test',
    )..addCommand(NamesSyncCommand(createApp))).run(['names:sync', ...args]);

    test(
      'writes names.dart, then --check passes until a route is added',
      () async {
        expect(await run(app()), 0);
        final file = File(p.join(project.path, 'lib', 'app', 'names.dart'));
        final written = file.readAsStringSync();
        expect(written, contains('static String postsShow({'));
        expect(written, contains("Ability('update-post')"));
        expect(written, contains("static const login = 'login';"));
        expect(await run(app(), ['--check']), 0);
        expect(await run(app(extra: true), ['--check']), 1);
        expect(file.readAsStringSync(), written);
        expect(await run(app(extra: true)), 0);
        expect(file.readAsStringSync(), contains('tagsIndex'));
      },
    );

    test('a provider that needs the database: a reason, exit 1', () async {
      Application failing() =>
          Application.configure(basePath: project.path)
              .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
              .withProviders([_QueriesAtBoot()])
              .create();
      expect(await run(failing), 1);
      expect(
        File(p.join(project.path, 'lib', 'app', 'names.dart')).existsSync(),
        isFalse,
      );
    });
  });

  test(
    'the process ends by itself: no timer, socket or file left open',
    () async {
      final dir = Directory(
        p.normalize(p.absolute('.dart_tool/names_sync_exit')),
      )..createSync(recursive: true);
      final project = Directory(p.join(dir.path, 'project'))
        ..createSync(recursive: true);
      File(p.join(project.path, 'pubspec.yaml'))
          .writeAsStringSync('name: shop\nenvironment:\n  sdk: ^3.13.0\n');
      Directory(p.join(project.path, 'bootstrap')).createSync(recursive: true);
      final script = File(p.join(dir.path, 'main.dart'))
        ..writeAsStringSync('''
import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/project_commands.dart';

Future<void> main(List<String> args) async {
  final code = await (CommandRunner<int>('dartisan', 'x')
        ..addCommand(NamesSyncCommand(() => Application.configure(basePath: args.first)
            .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', 'METRICS_ENABLED': 'true'})
            .withRouting(api: (r) => r.get('/a', (_) async => {}).name('a'))
            .create())))
      .run(['names:sync']);
  print('exit \$code');
}
''');
      // No exit() in the script: it must end once main returns.
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        script.path,
        project.path,
      ]).timeout(const Duration(minutes: 2));
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect('${result.stdout}', contains('exit 0'));
      expect(
        File(p.join(project.path, 'lib', 'app', 'names.dart')).existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

final class _QueriesAtBoot extends ServiceProvider {
  @override
  Future<void> boot(Container container) async {
    await DB.table('users').count();
  }
}
