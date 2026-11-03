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

  test('throttle:login: the sixth try in a minute gets a 429', () async {
    final wrong = {'email': 'student1@example.com', 'password': 'nope'};
    for (var i = 0; i < 5; i++) {
      (await client.post('/api/auth/login', json: wrong)).assertUnprocessable();
    }
    final blocked = await client.post('/api/auth/login', json: wrong)
      ..assertStatus(429);
    expect(blocked.headers['retry-after'], isNotNull);

    // Even the right password waits: the limit counts tries, not failures.
    (await client.post(
      '/api/auth/login',
      json: {'email': 'student1@example.com', 'password': 'password'},
    )).assertStatus(429);

    // The key is the email and address, so another account is not blocked.
    (await client.post(
      '/api/auth/login',
      json: {'email': 'teacher@example.com', 'password': 'password'},
    )).assertOk();
  });

  test('meeting data never reaches inline JavaScript', () async {
    final page = (await client.get('/', headers: {'Accept': 'text/html'})).body;
    // An onclick, onerror, ... attribute that interpolates a template
    // value: the browser decodes entities in the attribute before parsing
    // the JavaScript, so HTML escaping does not stop a quote in the value
    // from ending a JS string.
    final inlineInterpolation = RegExp(r'\son[a-z]+\s*=\s*"[^"]*\$\{');
    expect(inlineInterpolation.hasMatch(page), isFalse);
    expect(page, isNot(contains('handleJoinMeeting(\'')));
    expect(page, contains("addEventListener('click', () => handleJoinMeeting"));

    // A hostile name is stored and served as data, unchanged; the page
    // renders it through escapeHtml into text, never into code.
    const hostile = "x'); alert(document.cookie); ('</script><script>alert(1)";
    final classroomId = await app.run(
      () async => (await Classroom.query().first())!.id,
    );
    final created = await client
        .actingAs(teacher)
        .post(
          '/api/classrooms/$classroomId/meetings',
          json: {
            'name': hostile,
            'starts_at': '2030-01-01T08:00:00Z',
            'ends_at': '2030-01-01T09:00:00Z',
            'status': 'published',
          },
        );
    created.assertCreated().assertJsonPath('data.name', hostile);
  });

  test(
    'the livekit-client script is pinned with Subresource Integrity',
    () async {
      final page = (await client.get(
        '/',
        headers: {'Accept': 'text/html'},
      )).body;
      final tag = RegExp(
        r'<script src="https://cdn\.jsdelivr\.net/npm/livekit-client@[^"]+"[^>]*>',
      ).firstMatch(page)![0]!;
      expect(tag, contains('integrity="sha384-'));
      expect(tag, contains('crossorigin="anonymous"'));
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
