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

  test('Single-Device Exam Lock: prevents multi-device login, supports resumption, and proctor unlock', () async {
    const nik = '3201015508960002';
    const examNumber = 'TKA-2026-002';

    // 1. Initial login from Workstation A
    final firstLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'workstation_A_lab1',
        'duration_minutes': 30,
      },
    );

    firstLogin
        .assertOk()
        .assertJsonPath('status', 'created')
        .assertJsonPath('session.device_id', 'workstation_A_lab1');

    final tokenA = (firstLogin.json as Map<String, Object?>)['token'] as String;

    // Save answer on Workstation A
    await client
        .withToken(tokenA)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': 1,
            'selected_option': 'B',
            'is_doubtful': false,
            'idempotency_key': 'wsA_q1',
          },
        );

    // 2. Concurrent unauthorized login from Workstation B (different device)
    final secondLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'workstation_B_lab2',
        'duration_minutes': 30,
      },
    );

    // Must be rejected with HTTP 409 Conflict
    secondLogin
        .assertStatus(409)
        .assertJsonPath('error', 'DEVICE_LOCK_CONFLICT')
        .assertJsonPath('nik', nik)
        .assertJsonPath('locked_device', 'workstation_A_lab1')
        .assertJsonPath('attempted_device', 'workstation_B_lab2');

    // 3. Resumption from Workstation A (same device) succeeds without losing progress
    final resumeLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'workstation_A_lab1',
        'duration_minutes': 30,
      },
    );

    resumeLogin
        .assertOk()
        .assertJsonPath('status', 'resumed')
        .assertJsonPath('token', tokenA);

    final resumeData = resumeLogin.json as Map<String, Object?>;
    final answers = resumeData['answers'] as Map;
    expect(answers.containsKey('1'), isTrue);

    // 4. Proctor unlocks candidate's device (simulating hardware failure at exam site)
    final unlockResp = await client.post(
      '/api/exam/proctor/reset-lock',
      json: {
        'nik': nik,
        'reason': 'Workstation A monitor malfunction at Exam Room 1',
      },
    );

    unlockResp.assertOk().assertJsonPath('status', 'success');

    // 5. Workstation B can now seamlessly resume the exam!
    final takeoverLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'workstation_B_lab2',
        'duration_minutes': 30,
      },
    );

    takeoverLogin
        .assertOk()
        .assertJsonPath('status', 'resumed')
        .assertJsonPath('token', tokenA);

    final takeoverData = takeoverLogin.json as Map<String, Object?>;
    final preservedAnswers = takeoverData['answers'] as Map;
    expect(preservedAnswers.containsKey('1'), isTrue);

    // 6. CRITICAL SECURITY ASSERTION: Workstation C (third device / fraud attempt)
    // MUST BE REJECTED with HTTP 409 Conflict because candidate is now locked to Workstation B!
    final thirdPartyLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': nik,
        'exam_number': examNumber,
        'device_id': 'workstation_C_fraud',
        'duration_minutes': 30,
      },
    );

    thirdPartyLogin
        .assertStatus(409)
        .assertJsonPath('error', 'DEVICE_LOCK_CONFLICT')
        .assertJsonPath('locked_device', 'workstation_B_lab2')
        .assertJsonPath('attempted_device', 'workstation_C_fraud');
  });
}
