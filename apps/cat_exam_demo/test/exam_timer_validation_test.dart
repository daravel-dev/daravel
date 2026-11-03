import 'dart:io';

import '../database/seeders/candidate_seeder.dart';
import '../database/seeders/question_seeder.dart';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    freezeTime();
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{
        'APP_ENV': 'testing',
        'APP_KEY': 'base64:BNEJn3yBxEnOx6I6ZDHIS/FYAcmWWitfyf50dX7v0+c=',
        'DB_CONNECTION': 'sqlite',
        'DB_URL': 'sqlite::memory:',
      },
    );
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      await const CandidateSeeder().run();
      await const QuestionSeeder().run();
    });
    client = TestClient(app);
  });

  tearDown(() {
    travelBack();
    return app.shutdown();
  });

  test('Server-Side Exam Timer: strictly rejects submissions after deadline and grace period', () async {
    const nik = '3201012211940003';
    const examNumber = 'TKA-2026-003';

    // 1. Verify candidate with a 1-minute exam duration
    final verifyResp = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'pc_timer_test',
        'duration_minutes': 1,
      },
    );

    verifyResp.assertOk();
    final token = (verifyResp.json as Map<String, Object?>)['token'] as String;

    // 2. Answering within valid duration (at +20 seconds) succeeds
    travel(const Duration(seconds: 20));

    final validAnswer = await client
        .withToken(token)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': 1,
            'selected_option': 'A',
            'is_doubtful': false,
            'idempotency_key': 'timer_test_ans_1',
          },
        );

    validAnswer.assertOk().assertJsonPath('status', 'saved');

    // 3. Time travels past duration (1 minute) + grace period (15 seconds) -> advance by 60 more seconds (total 80s > 75s)
    travel(const Duration(seconds: 60));

    // Attempting to save answer now must be rejected with HTTP 410 Gone
    final expiredAnswer = await client
        .withToken(token)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': 2,
            'selected_option': 'B',
            'is_doubtful': false,
            'idempotency_key': 'timer_test_ans_2',
          },
        );

    expiredAnswer.assertStatus(410).assertJsonPath('error', 'EXAM_EXPIRED');

    // Attempting batch answers must also be rejected
    final expiredBatch = await client
        .withToken(token)
        .post(
          '/api/exam/batch-answers',
          json: {
            'answers': [
              {'question_id': 3, 'selected_option': 'C', 'is_doubtful': false},
            ],
          },
        );

    expiredBatch.assertStatus(410).assertJsonPath('error', 'EXAM_EXPIRED');

    // 4. Candidate re-verifying after timer expiry is auto-finalized without crashing
    final afterExpiryLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'pc_timer_test',
        'duration_minutes': 1,
      },
    );

    afterExpiryLogin
        .assertOk()
        .assertJsonPath('status', 'completed')
        .assertJsonPath('session.status', 'submitted');

    final afterExpiryData = afterExpiryLogin.json as Map<String, Object?>;
    expect(afterExpiryData.containsKey('session'), isTrue);
    expect(afterExpiryData['session'], isNotNull);
  });
}
