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
    expect(htmlResponse.body, contains('Virtual Classroom Daravel'));
    expect(htmlResponse.body, contains('daravel_livekit'));

    final jsonResponse = await client.get(
      '/',
      headers: {'Accept': 'application/json'},
    );
    jsonResponse.assertOk();
    jsonResponse.assertJsonPath('app', 'Virtual Classroom');
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
