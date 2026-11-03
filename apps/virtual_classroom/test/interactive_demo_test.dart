import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_permission/daravel_permission.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';
import 'package:virtual_classroom/app/models/classroom.dart';
import 'package:virtual_classroom/app/models/user.dart';

import '../bootstrap/app.dart';

void main() {
  late Directory dir;
  late Application app;
  late TestClient client;
  late User teacher;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('vc_demo_test_');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    app = createApp(
      basePath: dir.path,
      env: {
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'QUEUE_CONNECTION': 'sync',
        'LOG_LEVEL': 'error',
        'LIVEKIT_URL': 'wss://rtc.example.test',
        'LIVEKIT_API_KEY': 'devkey',
        'LIVEKIT_API_SECRET': 'a-livekit-secret-of-thirty-two-chars',
      },
    );
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      await Role.findOrCreate('teacher');
      await Role.findOrCreate('student');

      final pwd = await Hash.make('password');
      teacher = await User.query().create({
        'name': 'Teacher',
        'email': 'teacher@example.com',
        'password': pwd,
      });
      await teacher.assignRole('teacher');

      final classroom = await Classroom.query().create({
        'name': 'Mathematics 7A',
        'teacher_id': teacher.id,
      });

      final student = await User.query().create({
        'name': 'Student 1',
        'email': 'student1@example.com',
        'password': pwd,
      });
      await student.assignRole('student');
      await classroom.attach('students', student);
    });
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
  });

  test('GET / serves the interactive web client HTML and JSON info', () async {
    final htmlResponse = await client.get(
      '/',
      headers: {'Accept': 'text/html'},
    );
    htmlResponse.assertOk();
    expect(htmlResponse.body, contains('<html lang="en">'));
    expect(htmlResponse.body, contains('Schedule a new lesson'));
    expect(htmlResponse.body, contains('daravel_livekit'));
    expect(htmlResponse.body, contains('livekit-client@2.22.4'));

    final indonesian = await client.get(
      '/?lang=id',
      headers: {'Accept': 'text/html'},
    );
    expect(indonesian.body, contains('<html lang="id">'));
    expect(indonesian.body, contains('Jadwalkan Pelajaran Baru'));

    final jsonResponse = await client.get(
      '/',
      headers: {'Accept': 'application/json'},
    );
    jsonResponse.assertOk();
    jsonResponse.assertJsonPath('app', 'Virtual Classroom');
  });

  test(
    'POST /api/auth/login: a token, or a 422 in the request language',
    () async {
      final ok = await client.post(
        '/api/auth/login',
        json: {'email': 'teacher@example.com', 'password': 'password'},
      );
      ok.assertOk().assertJsonPath('user.role', 'teacher');

      final wrong = {'email': 'teacher@example.com', 'password': 'nope'};
      (await client.post(
        '/api/auth/login',
        json: wrong,
      )).assertUnprocessable().assertJsonPath(
        'errors.email.0',
        'These credentials do not match our records.',
      );
      (await client.post(
        '/api/auth/login',
        json: wrong,
        headers: {'accept-language': 'id'},
      )).assertJsonPath('errors.email.0', 'Email atau password tidak sesuai.');
    },
  );

  test('the demo endpoints answer 404 outside local and testing', () async {
    final key = base64Encode(List<int>.generate(32, (i) => i));
    final production = createApp(
      basePath: dir.path,
      env: {
        'APP_ENV': 'production',
        'APP_KEY': 'base64:$key',
        'DB_DATABASE': ':memory:',
        'LOG_LEVEL': 'error',
        'LIVEKIT_URL': 'wss://rtc.example.test',
        'LIVEKIT_API_KEY': 'devkey',
        'LIVEKIT_API_SECRET': 'a-livekit-secret-of-thirty-two-chars',
      },
    );
    await production.boot();
    addTearDown(production.shutdown);
    await production.run(() => App.make<Migrator>().run());
    final prod = TestClient(production);
    (await prod.post(
      '/api/auth/demo-switch',
      json: {'email': 'teacher@example.com'},
    )).assertNotFound();
    (await prod.get('/api/demo/state')).assertNotFound();
  });

  test('POST /api/auth/demo-switch issues token for user', () async {
    final response = await client.post(
      '/api/auth/demo-switch',
      json: {'email': 'teacher@example.com'},
    );
    response.assertOk();
    response.assertJsonPath('user.email', 'teacher@example.com');
    response.assertJsonPath('user.role', 'teacher');
    expect(response.jsonMap['token'], isNotEmpty);
  });

  test('GET /api/demo/state returns classrooms and users', () async {
    final response = await client.get('/api/demo/state');
    response.assertOk();
    response.assertJsonPath('classrooms.0.name', 'Mathematics 7A');
    expect(response.jsonMap['users'], isNotEmpty);
  });

  test('GET /api/activity-logs requires auth and returns logs', () async {
    (await client.get('/api/activity-logs')).assertUnauthorized();

    final authed = await client.actingAs(teacher).get('/api/activity-logs');
    authed.assertOk();
  });
}
