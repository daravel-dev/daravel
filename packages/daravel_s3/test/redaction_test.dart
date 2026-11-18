import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_s3/daravel_s3.dart';
import 'package:test/test.dart';

/// S3's connection errors show the endpoint and
/// the request with the password and sensitive query values masked, in the
/// message, the log and the debug error page; a sub-second timeout reads in
/// milliseconds.
void main() {
  const secrets = ['PASS', 'SESSIONTOKEN', 'TOKENVALUE'];
  const query = {
    'X-Amz-Security-Token': 'SESSIONTOKEN',
    'token': 'TOKENVALUE',
    'page': '2',
  };
  const signer = SigV4Signer(
    accessKey: 'AKID',
    secretKey: 'secret',
    region: 'us-east-1',
  );

  void expectRedacted(String text) {
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)), reason: text);
    }
    expect(text, contains('page=2'), reason: text);
  }

  S3Client client(String endpoint, {Duration? timeout}) => S3Client(
    signer: signer,
    bucket: 'b',
    endpoint: endpoint,
    pathStyle: true,
    retries: 0,
    retryDelay: Duration.zero,
    timeout: timeout ?? const Duration(seconds: 5),
  );

  test('config:show (toMap) masks the endpoint and the URL', () {
    final map = const S3Config(
      endpoint: 'http://user:PASS@minio.test:9000?token=TOKENVALUE&page=2',
      url: 'https://cdn.test/b?X-Amz-Security-Token=SESSIONTOKEN&page=2',
    ).toMap();
    expectRedacted('${map['endpoint']}');
    expectRedacted('${map['url']}');
    expect(const S3Config().toMap()['endpoint'], isNull);
  });

  test('a connection that fails shows the URL redacted', () async {
    // Nothing listens on port 1: refused at once.
    Object? error;
    try {
      await client('http://user:PASS@127.0.0.1:1')
          .send('GET', 'k', query: query);
    } on ConnectionException catch (e) {
      error = e;
    }
    expect(error, isA<ConnectionException>());
    expectRedacted('$error');
  });

  test('a sub-second timeout reads in milliseconds, redacted', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.listen((_) {}));
    Object? error;
    try {
      await client(
        'http://user:PASS@127.0.0.1:${server.port}',
        timeout: const Duration(milliseconds: 300),
      ).send('GET', 'k', query: query);
    } on ConnectionException catch (e) {
      error = e;
    }
    expect('$error', contains('300ms'));
    expectRedacted('$error');
  });

  test(
    'with APP_DEBUG, the error body and the log show the URL redacted',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_DEBUG': 'true',
            'DB_DATABASE': ':memory:',
          })
          .withLogLevel(LogLevel.debug)
          .withRouting(
            web: (router) => router.get('/call', (Request request) async {
              await client('http://user:PASS@127.0.0.1:1')
                  .send('GET', 'k', query: query);
              return 'unreachable';
            }),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final logs = await app.run(() async => Log.spy());
      final response = await app.handle(
        Request.fake(method: 'GET', path: '/call'),
      );
      final body = await response.bodyText();
      expect(response.status, 500);
      expect(body, contains('Could not reach'));
      expectRedacted(body);
      final logged = logs.records
          .map((r) => '${r.message} ${r.context} ${r.error ?? ''}')
          .join('\n');
      expect(logged, contains('Could not reach'));
      expectRedacted(logged);
    },
  );
}
