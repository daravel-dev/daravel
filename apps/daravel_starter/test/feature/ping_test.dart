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
      env: <String, String>{
        'APP_ENV': 'testing',
        'APP_NAME': 'Starter',
        'DB_DATABASE': ':memory:',
      },
    );
    await app.boot();
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  test('GET /up reports the application is healthy', () async {
    (await client.get('/up'))
        .assertOk()
        .assertJsonPath('status', 'ok')
        .assertJsonPath('app', 'Starter')
        .assertHeader('x-request-id');
  });

  test('GET /api/ping pongs with request metadata', () async {
    final response = (await client.get('/api/ping'))
        .assertOk()
        .assertHeader('content-type', 'application/json')
        .assertJson(<String, Object?>{'message': 'pong', 'app': 'Starter'});
    expect(response.jsonMap['request_id'], response.headers['x-request-id']);
    expect(response.jsonMap['timestamp'], isA<String>());
  });

  test('unknown routes render JSON 404', () async {
    (await client.get('/api/nope')).assertNotFound().assertJson(
      <String, Object?>{'message': 'The route api/nope could not be found.'},
    );
  });

  test('unsupported methods render 405 with Allow', () async {
    (await client.post(
      '/api/ping',
      json: <String, Object?>{},
    )).assertMethodNotAllowed().assertHeader('allow', 'GET, HEAD');
  });

  test('route parameters are typed', () async {
    (await client.get('/api/users/not-a-number')).assertNotFound();
  });
}
