import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

/// A server that makes every mistake the audit looks for.
Future<HttpServer> vulnerableServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    final raw = request.uri.toString();
    final body = await utf8.decodeStream(request);
    void send(int status, String text, {String type = 'text/plain'}) {
      response
        ..statusCode = status
        ..headers.set('content-type', type)
        ..write(text);
    }

    response.headers
      ..set('server', 'Apache/2.4.1')
      ..set('x-powered-by', 'PHP/8.1.2');
    final origin = request.headers.value('origin');
    if (origin != null) {
      response.headers
        ..set('access-control-allow-origin', origin)
        ..set('access-control-allow-credentials', 'true');
    }
    const env = 'APP_ENV=production\nAPP_KEY=base64:secret\nDB_PASSWORD=x\n';
    final lower = raw.toLowerCase();
    if (request.method == 'TRACE') {
      final echoed = StringBuffer('TRACE / HTTP/1.1\n');
      request.headers.forEach((name, values) {
        echoed.writeln('$name: ${values.join(',')}');
      });
      send(200, echoed.toString(), type: 'message/http');
    } else if (lower.contains('%0d%0a')) {
      final injected = Uri.decodeComponent(raw.split('%0D%0A').last);
      response.headers.set('x-daravel-audit', injected.split(':').last.trim());
      send(200, 'ok');
    } else if (lower.contains('..%2f') || lower.contains('%2e%2e')) {
      send(200, env);
    } else {
      switch (request.uri.path) {
        case '/':
          if (request.method == 'POST') {
            send(
              500,
              'FormatException\n#0      main (file:///srv/bin/server.dart:12:3)',
            );
          } else {
            response.headers.add('set-cookie', 'session=abc; Path=/');
            send(200, '<html><body>home</body></html>', type: 'text/html');
          }
        case '/.env':
          send(200, env);
        case '/.git/HEAD':
          send(200, 'ref: refs/heads/main\n');
        case '/.git/config':
          send(200, '[core]\n\trepositoryformatversion = 0\n');
        case '/metrics':
          send(200, '# TYPE http_requests_total counter\n');
        case '/log-viewer/api/files':
          send(200, '{"files":[]}', type: 'application/json');
        case '/api/echo':
          send(
            body.length > 1000 ? 500 : 200,
            body.length > 1000 ? 'stack overflow' : '{}',
          );
        default:
          send(
            404,
            'Not found\n#0      Router.match (package:app/router.dart:40:7)',
          );
      }
    }
    await response.close();
  });
  return server;
}

/// A Daravel application with the middleware new projects get.
Future<(Application, ServerEngine)> daravelServer() async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({
        'APP_ENV': 'production',
        'APP_DEBUG': 'false',
        'APP_KEY': 'base64:${base64.encode(List.filled(32, 7))}',
        'DB_DATABASE': ':memory:',
        'LOG_LEVEL': 'critical',
      })
      .withRouting(
        web: (r) => r.get('/', (_) => Response.html('<h1>home</h1>')),
        api: (r) => r.post('/echo', (Request request) async {
          final data = await request.validate({'items': 'array'});
          return data.toMap();
        }),
      )
      .withMiddleware((middleware) {
        middleware.use(const <Middleware>[
          SecurityHeadersMiddleware(),
          BodyLimitsMiddleware(),
        ]);
      })
      .create();
  await app.boot();
  final engine = ServerEngine(
    app,
    const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
    kernel: app.kernel,
    logger: Logger(minimumLevel: LogLevel.critical),
  );
  await engine.start();
  return (app, engine);
}

void main() {
  test('finds every mistake of a misconfigured server', () async {
    final server = await vulnerableServer();
    addTearDown(() => server.close(force: true));
    final result = await SecurityAudit(
      Uri.parse('http://127.0.0.1:${server.port}'),
      jsonPath: '/api/echo',
    ).run();
    final failed = {for (final f in result.findings) f.check.id};
    expect(failed, {
      for (final check in SecurityAudit.all)
        if (check != SecurityAudit.plainHttp) check.id,
    });
    expect(result.skipped, isEmpty);
    String? severityOf(String message) => result.findings
        .where((f) => f.message.contains(message))
        .firstOrNull
        ?.severity
        .name;
    expect(severityOf('/.env is served'), 'critical');
    expect(severityOf('reflected'), 'high');
    expect(severityOf('stack trace'), 'high');
    expect(result.failsAt(AuditSeverity.critical), isTrue);

    final text = renderAudit(result);
    expect(text, contains('FAIL  DARAVEL-SEC-003  Sensitive files served'));
    expect(text, contains('Fix: Serve only the public directory'));

    final sarif = auditSarif(result, version: '9.9.9');
    final run = (sarif['runs']! as List).single as Map<String, Object?>;
    final results = run['results']! as List;
    expect(results, hasLength(result.findings.length));
    expect((results.first as Map)['level'], isIn(['error', 'warning', 'note']));
    expect(jsonEncode(sarif), contains('"version":"2.1.0"'));
  });

  test('a Daravel application with the default middleware passes', () async {
    final (app, engine) = await daravelServer();
    addTearDown(() async {
      await engine.stop();
      await app.shutdown();
    });
    final result = await SecurityAudit(
      Uri.parse('http://127.0.0.1:${engine.port}'),
      jsonPath: '/api/echo',
    ).run();
    expect([
      for (final f in result.findings) '${f.check.id}: ${f.message}',
    ], isEmpty);
    expect(result.skipped, isEmpty);
    expect(auditJson(result)['findings'], isEmpty);
  });

  test('plain HTTP is a finding away from local hosts only', () async {
    Future<List<AuditFinding>> on(String url) async => (await SecurityAudit(
      Uri.parse(url),
      transport: (method, path, {headers = const {}, body}) async =>
          const ProbeResponse(404, {}, ''),
    ).run(only: {'plainhttp'})).findings;
    expect(await on('http://127.0.0.1:8000'), isEmpty);
    expect(await on('http://shop.ddev.site'), isEmpty);
    expect(await on('https://example.com'), isEmpty);
    expect(
      (await on('http://example.com')).single.severity,
      AuditSeverity.medium,
    );
  });

  test('security:audit exits 1 at the severity and writes SARIF', () async {
    final server = await vulnerableServer();
    addTearDown(() => server.close(force: true));
    final dir = Directory.systemTemp.createTempSync('daravel_audit_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Future<int?> dartisan(List<String> args) =>
        DartisanRunner(
          () =>
              Application.configure(basePath: dir.path)
                  .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
                  .create(),
        ).run([
          'security:audit',
          '--target=http://127.0.0.1:${server.port}',
          ...args,
        ]);

    expect(await dartisan(['--only=011', '--severity=high']), 0);
    expect(await dartisan(['--only=011', '--severity=medium']), 1);
    final sarif = '${dir.path}/audit.sarif';
    expect(await dartisan(['--format=sarif', '--output=$sarif']), 1);
    final written = jsonDecode(File(sarif).readAsStringSync()) as Map;
    expect(written['version'], '2.1.0');
    expect(await dartisan(['--timeout=0']), 64);
  });
}
