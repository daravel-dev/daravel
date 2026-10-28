import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';
import 'package:daravel_google/daravel_google.dart';
import 'package:daravel_livekit/daravel_livekit.dart';
import 'package:daravel_permission/daravel_permission.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';
import 'package:virtual_classroom/app/models/classroom.dart';
import 'package:virtual_classroom/app/models/meeting.dart';
import 'package:virtual_classroom/app/models/user.dart';

import '../bootstrap/app.dart';

const livekitKey = 'devkey';
const livekitSecret = 'a-livekit-secret-of-thirty-two-chars';

/// A Google service account key made for the run (no key in the
/// repository): PEM PKCS#8, as Google writes it.
String serviceAccountJson() {
  final seed = Random.secure();
  final random = FortunaRandom()
    ..seed(
      KeyParameter(
        Uint8List.fromList([for (var i = 0; i < 32; i++) seed.nextInt(256)]),
      ),
    );
  final keys =
      (RSAKeyGenerator()..init(
            ParametersWithRandom(
              RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
              random,
            ),
          ))
          .generateKeyPair();
  final key = keys.privateKey;
  final d = key.privateExponent!;
  final p = key.p!;
  final q = key.q!;
  final rsa = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Integer(key.modulus),
      ASN1Integer(key.publicExponent),
      ASN1Integer(d),
      ASN1Integer(p),
      ASN1Integer(q),
      ASN1Integer(d % (p - BigInt.one)),
      ASN1Integer(d % (q - BigInt.one)),
      ASN1Integer(q.modInverse(p)),
    ],
  );
  final info = ASN1Sequence(
    elements: [
      ASN1Integer(BigInt.zero),
      ASN1Sequence(
        elements: [
          ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
          ASN1Null(),
        ],
      ),
      ASN1OctetString(octets: rsa.encode()),
    ],
  );
  final text = base64.encode(info.encode());
  final lines = [
    for (var i = 0; i < text.length; i += 64)
      text.substring(i, min(i + 64, text.length)),
  ];
  return jsonEncode({
    'type': 'service_account',
    'project_id': 'demo',
    'private_key_id': 'kid-1',
    'private_key':
        '-----BEGIN PRIVATE KEY-----\n${lines.join('\n')}\n'
        '-----END PRIVATE KEY-----\n',
    'client_email': 'calendar@demo.iam.gserviceaccount.com',
    'token_uri': GoogleServiceAccount.defaultTokenUri,
  });
}

void main() {
  late Directory dir;
  late Application app;
  late TestClient client;
  late HttpFake http;
  late User teacher;
  late User otherTeacher;
  late User ana;
  late User bo;
  late User outsider;
  late Classroom classroom;
  final calendarEvents = <Map<String, Object?>>[];

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('virtual_classroom_');
    File('${dir.path}/service-account.json')
        .writeAsStringSync(serviceAccountJson());
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() async {
    Clock.fake(DateTime.utc(2026, 11, 2, 7, 0));
    calendarEvents.clear();
    app = createApp(
      basePath: dir.path,
      env: {
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'QUEUE_CONNECTION': 'sync',
        'LOG_LEVEL': 'error',
        'LIVEKIT_URL': 'wss://rtc.example.test',
        'LIVEKIT_API_KEY': livekitKey,
        'LIVEKIT_API_SECRET': livekitSecret,
        'GOOGLE_APPLICATION_CREDENTIALS': '${dir.path}/service-account.json',
        'GOOGLE_CALENDAR_ID': 'school@example.test',
      },
    );
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      http = App.make<HttpClientFactory>().fake({
        GoogleServiceAccount.defaultTokenUri: Http.response({
          'access_token': 'ya29.test',
          'expires_in': 3599,
          'token_type': 'Bearer',
        }),
        '*/twirp/livekit.RoomService/CreateRoom': (ClientRequest request) =>
            Http.response({
              ...request.json()! as Map<String, Object?>,
              'sid': 'RM_1',
            }),
        'https://www.googleapis.com/calendar/*': (ClientRequest request) {
          calendarEvents.add({
            'method': request.method,
            'path': request.url.path,
            if (request.body.isNotEmpty)
              ...request.json()! as Map<String, Object?>,
          });
          return request.method == 'DELETE'
              ? Http.response(null, 204)
              : Http.response({'id': 'evt-1'});
        },
      });
      await Role.findOrCreate('teacher');
      await Role.findOrCreate('student');
      Future<User> user(String name, String role) async {
        final user = await User.query().create({
          'name': name,
          'email': '${name.toLowerCase()}@example.test',
          'password': 'x',
        });
        await user.assignRole(role);
        return user;
      }

      teacher = await user('Teacher', 'teacher');
      otherTeacher = await user('Other', 'teacher');
      ana = await user('Ana', 'student');
      bo = await user('Bo', 'student');
      outsider = await user('Outsider', 'student');
      classroom = await Classroom.query().create({
        'name': 'Mathematics 7A',
        'teacher_id': teacher.id,
      });
      await classroom.attach('students', [ana.id, bo.id]);
    });
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    Clock.restore();
  });

  Map<String, Object?> lesson([Map<String, Object?> extra = const {}]) => {
    'name': 'Fractions',
    'description': 'Adding fractions with unlike denominators',
    'starts_at': '2026-11-02T07:30:00Z',
    'ends_at': '2026-11-02T08:15:00Z',
    'max_participants': 40,
    'status': 'published',
    ...extra,
  };

  Future<String> schedule([Map<String, Object?> extra = const {}]) async {
    final response = await client
        .actingAs(teacher)
        .post('/api/classrooms/${classroom.id}/meetings', json: lesson(extra));
    response.assertCreated();
    return (response.jsonMap['data']! as Map<String, Object?>)['id']! as String;
  }

  test('the teacher schedules a lesson; the students are invited', () async {
    final id = await schedule();
    final created = calendarEvents.single;
    expect(created['method'], 'POST');
    expect(
      created['path'],
      '/calendar/v3/calendars/school%40example.test/events',
    );
    expect(created['summary'], 'Mathematics 7A: Fractions');
    expect(created['attendees'], [
      {'email': 'ana@example.test'},
      {'email': 'bo@example.test'},
    ]);
    await app.run(() async {
      final meeting = await Meeting.query().where('uuid', id).first();
      expect(meeting!.calendarEventId, 'evt-1');
      final activity = await Activity.query().inLog('meetings').first();
      expect(activity!.event, 'created');
    });
  });

  test('only the classroom\'s teacher writes', () async {
    (await client
            .actingAs(ana)
            .post('/api/classrooms/${classroom.id}/meetings', json: lesson()))
        .assertForbidden();
    (await client
            .actingAs(otherTeacher)
            .post('/api/classrooms/${classroom.id}/meetings', json: lesson()))
        .assertForbidden();
    (await client
            .actingAs(teacher)
            .post(
              '/api/classrooms/${classroom.id}/meetings',
              json: lesson({'ends_at': '2026-11-02T07:00:00Z'}),
            ))
        .assertUnprocessable()
        .assertJsonValidationErrors(['ends_at']);
    final id = await schedule();
    (await client
            .actingAs(otherTeacher)
            .patch('/api/meetings/$id', json: {'name': 'Mine now'}))
        .assertForbidden();
  });

  test('students see the published lessons of their classrooms', () async {
    await schedule();
    await schedule({'name': 'Decimals (draft)', 'status': 'draft'});
    (await client.actingAs(ana).get('/api/meetings'))
        .assertOk()
        .assertJsonPath('data.0.name', 'Fractions')
        .assertJsonCount(1, 'data');
    (await client.actingAs(teacher).get('/api/meetings'))
        .assertOk()
        .assertJsonCount(2, 'data');
    (await client.actingAs(teacher).get('/api/meetings?q=decimal'))
        .assertJsonCount(1, 'data');
    (await client.actingAs(outsider).get('/api/meetings'))
        .assertJsonCount(0, 'data');
    (await client.get('/api/meetings')).assertUnauthorized();
  });

  test('joining: the room opens 15 minutes early; tokens by role', () async {
    final id = await schedule();
    (await client.actingAs(ana).post('/api/meetings/$id/join'))
        .assertStatus(409);
    (await client.actingAs(outsider).post('/api/meetings/$id/join'))
        .assertForbidden();

    Clock.fake(DateTime.utc(2026, 11, 2, 7, 20));
    final student = (await client.actingAs(ana).post('/api/meetings/$id/join'))
      ..assertOk();
    final teacherPass =
        (await client.actingAs(teacher).post('/api/meetings/$id/join'))
          ..assertOk();
    final createRoom = http.recorded
        .where((r) => r.url.path.endsWith('/CreateRoom'))
        .first;
    expect(createRoom.json('max_participants'), 40);

    Future<LivekitClaims> claims(TestResponse response) => LivekitToken.verify(
      response.jsonMap['token']! as String,
      apiKey: livekitKey,
      apiSecret: livekitSecret,
    );
    final anaClaims = await claims(student);
    expect(anaClaims.identity, 'user-${ana.id}');
    expect(anaClaims.video!.roomJoin, isTrue);
    expect(anaClaims.video!.roomAdmin, isNot(true));
    expect(anaClaims.expiresAt, DateTime.utc(2026, 11, 2, 8, 30));
    expect((await claims(teacherPass)).video!.roomAdmin, isTrue);
    expect(student.jsonMap['url'], 'wss://rtc.example.test');

    Clock.fake(DateTime.utc(2026, 11, 2, 8, 15));
    (await client.actingAs(ana).post('/api/meetings/$id/join'))
        .assertStatus(409);
  });

  test(
    'unpublishing and deleting take the event out of the calendar',
    () async {
      final id = await schedule();
      (await client
              .actingAs(teacher)
              .patch('/api/meetings/$id', json: {'status': 'draft'}))
          .assertOk();
      expect(calendarEvents.last['method'], 'DELETE');
      (await client.actingAs(ana).get('/api/meetings/$id')).assertForbidden();

      (await client
              .actingAs(teacher)
              .patch('/api/meetings/$id', json: {'status': 'published'}))
          .assertOk();
      expect(calendarEvents.last['method'], 'POST');
      (await client.actingAs(teacher).delete('/api/meetings/$id'))
          .assertNoContent();
      expect(calendarEvents.last['method'], 'DELETE');
      expect(calendarEvents.last['path'], endsWith('/events/evt-1'));
    },
  );
}
