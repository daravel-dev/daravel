import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `php artisan route:list --json` of Laravel 12 (RouteListCommand::
/// getRouteInformation: domain, method "GET|HEAD", uri without its leading
/// slash, name, action, middleware as a list, path, vendor).
final String laravelRoutes = jsonEncode([
  for (final (method, uri) in [
    ('GET|HEAD', '/'),
    ('GET|HEAD', 'api/orders'),
    ('POST', 'api/orders'),
    ('GET|HEAD', 'api/orders/{order}'),
    ('PUT|PATCH', 'api/orders/{order}'),
    ('GET|HEAD', 'api/reports/sales-pdf'),
    ('POST', 'api/webhooks/stripe'),
  ])
    {
      'domain': null,
      'method': method,
      'uri': uri,
      'name': null,
      'action': r'App\Http\Controllers\OrderController@index',
      'middleware': ['api'],
      'path': null,
      'vendor': false,
    },
]);

Application createApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'LOG_LEVEL': 'emergency',
        })
        .withRouting(
          web: (r) => r.get('/', (_) => 'home'),
          api: (r) {
            r
              ..get('/orders', (_) => const <Object?>[])
              ..get('/orders/{id}', (_) => const <String, Object?>{})
              ..patch('/orders/{id}', (_) => const <String, Object?>{})
              ..get('/metrics/new', (_) => const <String, Object?>{});
          },
          health: null,
        )
        .create();

void main() {
  test('parses route:list --json one method at a time, without HEAD', () {
    final routes = RouteDiff.parseLaravel(laravelRoutes);
    expect(routes, hasLength(8));
    expect(routes.where((r) => r.method == 'HEAD'), isEmpty);
    expect(routes, contains((method: 'PUT', uri: 'api/orders/{order}')));
    expect(
      () => RouteDiff.parseLaravel('{"not": "a list"}'),
      throwsFormatException,
    );
  });

  test('migrated, still Laravel and Daravel only; parameter names do not '
      'matter', () {
    final diff = RouteDiff.compute(RouteDiff.parseLaravel(laravelRoutes), [
      (method: 'GET', uri: '/'),
      (method: 'GET', uri: '/api/orders'),
      (method: 'GET', uri: '/api/orders/{id}'),
      (method: 'PATCH', uri: '/api/orders/{id?}'),
      (method: 'GET', uri: '/api/metrics/new'),
    ]);
    expect(diff.total, 8);
    expect(diff.migrated, [
      (method: 'GET', uri: '/'),
      (method: 'GET', uri: 'api/orders'),
      (method: 'GET', uri: 'api/orders/{order}'),
      (method: 'PATCH', uri: 'api/orders/{order}'),
    ]);
    expect(
      [for (final r in diff.legacy) '${r.method} ${r.uri}'],
      [
        'POST api/orders',
        'PUT api/orders/{order}',
        'GET api/reports/sales-pdf',
        'POST api/webhooks/stripe',
      ],
    );
    expect(diff.daravelOnly, [(method: 'GET', uri: '/api/metrics/new')]);
    expect(diff.percent, 50);
    final text = diff.render();
    expect(
      text,
      contains('Migrated                : 50.0% [██████████░░░░░░░░░░]'),
    );
    expect(text, contains('POST   /api/webhooks/stripe'));
    expect(text, contains('LARAVEL'));
  });

  test('route:diff against this application, as JSON', () async {
    final dir = Directory.systemTemp.createTempSync('route_diff_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'routes.json'))
      ..writeAsStringSync(laravelRoutes);
    final lines = <String>[];
    final code = await IOOverrides.runZoned(
      () =>
          DartisanRunner(createApp)
              .run(['route:diff', '--laravel-json=${file.path}', '--json']),
      stdout: () => _Capture(lines),
    );
    expect(code, 0);
    final diff = jsonDecode(lines.join()) as Map<String, Object?>;
    expect(diff['total'], 8);
    expect(diff['percent'], 50);
    expect(diff['daravel_only'], [
      {'method': 'GET', 'uri': '/api/metrics/new'},
    ]);

    expect(
      () => DartisanRunner(createApp).run(['route:diff']),
      throwsA(isA<UsageException>()),
    );
  });
}

/// Collects what a command writes to stdout.
final class _Capture implements Stdout {
  _Capture(this.lines);
  final List<String> lines;

  @override
  void writeln([Object? object = '']) => lines.add('$object');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
