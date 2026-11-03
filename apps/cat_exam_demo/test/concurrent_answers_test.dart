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

  tearDown(() => app.shutdown());

  test('High-Concurrency & Idempotency: handles 50 parallel auto-save bursts without data corruption', () async {
    // 1. Candidate login
    final verifyResp = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201014405970004',
        'exam_number': 'TKA-2026-004',
        'device_id': 'pc_stress_01',
        'duration_minutes': 30,
      },
    );

    verifyResp.assertOk();
    final token = (verifyResp.json as Map<String, Object?>)['token'] as String;

    // 2. Fire 50 concurrent async auto-save requests in parallel across questions 1 to 15
    const totalConcurrentRequests = 50;
    final futures = <Future<TestResponse>>[];

    for (var i = 0; i < totalConcurrentRequests; i++) {
      final qId = (i % 15) + 1;
      final option = ['A', 'B', 'C', 'D', 'E'][i % 5];
      final isDoubtful = i % 3 == 0;
      final idempotencyKey = 'idem_burst_${qId}_${i ~/ 15}';

      futures.add(
        client
            .withToken(token)
            .post(
              '/api/exam/answer',
              json: {
                'question_id': qId,
                'selected_option': option,
                'is_doubtful': isDoubtful,
                'idempotency_key': idempotencyKey,
              },
            ),
      );
    }

    final responses = await Future.wait(futures);

    // All 50 concurrent requests must complete successfully with HTTP 200
    for (final resp in responses) {
      resp.assertOk().assertJsonPath('status', 'saved');
    }

    // 3. Verify Idempotency: repeating an identical request with the same idempotency key
    final repeatedResp = await client
        .withToken(token)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': 1,
            'selected_option': 'B',
            'is_doubtful': false,
            'idempotency_key': 'idem_burst_1_0',
          },
        );

    repeatedResp.assertOk().assertJsonPath('status', 'saved');

    // 4. Verify that session state holds clean, non-duplicated answers
    final sessResp = await client.withToken(token).get('/api/exam/session');
    sessResp.assertOk();
    final sessData = sessResp.json as Map<String, Object?>;
    final answers = sessData['answers'] as Map;

    // Must have exactly 15 answered questions (no duplicated keys or phantom rows)
    expect(answers.length, 15);
  });
}
