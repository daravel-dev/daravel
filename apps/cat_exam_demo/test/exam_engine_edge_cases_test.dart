import 'dart:io';

import 'package:cat_exam_demo/app/models/candidate.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../bootstrap/app.dart';
import '../database/seeders/candidate_seeder.dart';
import '../database/seeders/question_seeder.dart';

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

  group('Exam Engine Edge Cases & Input Validation', () {
    test('Whitespace in device_id and credentials is sanitized without false conflict on resume', () async {
      const rawNik = '  3201011203950001  ';
      const rawExamNo = '  TKA-2026-001  ';
      const rawDeviceId = '  pc_whitespace_lab_1  ';

      // 1. Initial login with raw untrimmed strings
      final loginResp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': rawNik,
          'exam_number': rawExamNo,
          'device_id': rawDeviceId,
          'duration_minutes': 30,
        },
      );
      loginResp.assertOk().assertJsonPath('status', 'created');

      // 2. Resume with clean trimmed strings on the same device
      final resumeResp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201011203950001',
          'exam_number': 'TKA-2026-001',
          'device_id': 'pc_whitespace_lab_1',
        },
      );
      resumeResp.assertOk().assertJsonPath('status', 'resumed');
    });

    test('Empty device_id falls back to browser fingerprint', () async {
      final loginResp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201015508960002',
          'exam_number': 'TKA-2026-002',
          'device_id': '',
        },
      );
      loginResp.assertOk().assertJsonPath('status', 'created');
      final data = loginResp.json as Map<String, Object?>;
      final session = data['session'] as Map<String, Object?>;
      final devId = session['device_id'] as String;
      expect(devId, startsWith('browser_'));
    });

    test('Missing NIK or Exam Number returns 422 VALIDATION_ERROR', () async {
      final resp = await client.post(
        '/api/exam/verify',
        json: {'nik': '', 'exam_number': 'TKA-2026-001'},
      );
      resp.assertStatus(422).assertJsonPath('error', 'VALIDATION_ERROR');
    });

    test('Non-existent candidate returns 404 AUTH_FAILED', () async {
      final resp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '9999999999999999',
          'exam_number': 'TKA-NONEXIST',
          'device_id': 'pc_1',
        },
      );
      resp.assertStatus(404).assertJsonPath('error', 'AUTH_FAILED');
    });

    test('Invalid selected_option returns 422 VALIDATION_ERROR', () async {
      final loginResp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201012211940003',
          'exam_number': 'TKA-2026-003',
          'device_id': 'pc_opt_test',
        },
      );
      loginResp.assertOk();
      final token = (loginResp.json as Map<String, Object?>)['token'] as String;

      final invalidOpt = await client
          .withToken(token)
          .post(
            '/api/exam/answer',
            json: {
              'question_id': 1,
              'selected_option': 'Z', // Invalid option!
              'is_doubtful': false,
            },
          );
      invalidOpt.assertStatus(422).assertJsonPath('error', 'VALIDATION_ERROR');
    });

    test('Out-of-range question_id returns 422 VALIDATION_ERROR', () async {
      final loginResp = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201012211940003',
          'exam_number': 'TKA-2026-003',
          'device_id': 'pc_q_test',
        },
      );
      loginResp.assertOk();
      final token = (loginResp.json as Map<String, Object?>)['token'] as String;

      final outOfRange = await client
          .withToken(token)
          .post(
            '/api/exam/answer',
            json: {
              'question_id': 99, // Out of range!
              'selected_option': 'A',
              'is_doubtful': false,
            },
          );
      outOfRange.assertStatus(422).assertJsonPath('error', 'VALIDATION_ERROR');

      final zeroQ = await client
          .withToken(token)
          .post(
            '/api/exam/answer',
            json: {
              'question_id': 0,
              'selected_option': 'A',
              'is_doubtful': false,
            },
          );
      zeroQ.assertStatus(422).assertJsonPath('error', 'VALIDATION_ERROR');
    });

    test(
      'Batch answers safely parses string question IDs and boolean string',
      () async {
        final loginResp = await client.post(
          '/api/exam/verify',
          json: {
            'nik': '3201014405970004',
            'exam_number': 'TKA-2026-004',
            'device_id': 'pc_batch_edge',
          },
        );
        loginResp.assertOk();
        final token =
            (loginResp.json as Map<String, Object?>)['token'] as String;

        final batchResp = await client
            .withToken(token)
            .post(
              '/api/exam/batch-answers',
              json: {
                'answers': [
                  {
                    'question_id': '1', // String ID!
                    'selected_option': 'C',
                    'is_doubtful': 'true', // String boolean!
                  },
                  {
                    'question_id': 999, // Invalid ID, should be skipped
                    'selected_option': 'B',
                    'is_doubtful': false,
                  },
                  {
                    'question_id': 2,
                    'selected_option': 'A',
                    'is_doubtful': false,
                  },
                ],
              },
            );

        batchResp
            .assertOk()
            .assertJsonPath('status', 'batch_saved')
            .assertJsonPath('saved_count', 2); // 1 and 2 saved, 999 skipped
      },
    );

    test(
      'Result lookup on unsubmitted exam returns 400 EXAM_NOT_SUBMITTED',
      () async {
        final loginResp = await client.post(
          '/api/exam/verify',
          json: {
            'nik': '3201015508960002',
            'exam_number': 'TKA-2026-002',
            'device_id': 'pc_unsubmitted',
          },
        );
        loginResp.assertOk();
        final session =
            (loginResp.json as Map<String, Object?>)['session']
                as Map<String, Object?>;
        final sessionId = session['id'] as String;

        final resResp = await client.get('/api/exam/result/$sessionId');
        resResp.assertStatus(400).assertJsonPath('error', 'EXAM_NOT_SUBMITTED');
      },
    );

    test('Proctor unlock with whitespace in NIK succeeds and non-existent NIK returns 404', () async {
      // 1. Proctor unlock with untrimmed valid NIK
      final unlockValid = await client.post(
        '/api/exam/proctor/reset-lock',
        json: {
          'nik': '  3201011203950001  ',
          'reason': 'Proctor reset with whitespace',
        },
      );
      unlockValid.assertOk().assertJsonPath('status', 'success');

      final cand = await Candidate.where('nik', '3201011203950001').first();
      expect(cand?.deviceId, isNull);

      // 2. Proctor unlock for non-existent candidate
      final unlockInvalid = await client.post(
        '/api/exam/proctor/reset-lock',
        json: {'nik': '0000000000000000', 'reason': 'Ghost candidate'},
      );
      unlockInvalid.assertStatus(404).assertJsonPath('error', 'NOT_FOUND');
    });

    test('Leaderboard pagination: limit query preserves accurate total_completed count', () async {
      // Submit candidate 1
      final l1 = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201011203950001',
          'exam_number': 'TKA-2026-001',
          'device_id': 'pc_lb_1',
        },
      );
      final t1 = (l1.json as Map<String, Object?>)['token'] as String;
      await client.withToken(t1).post('/api/exam/finish');

      // Submit candidate 2
      final l2 = await client.post(
        '/api/exam/verify',
        json: {
          'nik': '3201015508960002',
          'exam_number': 'TKA-2026-002',
          'device_id': 'pc_lb_2',
        },
      );
      final t2 = (l2.json as Map<String, Object?>)['token'] as String;
      await client.withToken(t2).post('/api/exam/finish');

      // Query with limit=1: total_completed must be 2, showing must be 1
      final lbResp = await client.get('/api/exam/leaderboard?limit=1');
      lbResp.assertOk();
      lbResp.assertJsonPath('total_completed', 2);
      lbResp.assertJsonPath('showing', 1);

      final lbList =
          ((lbResp.json as Map<String, Object?>)['leaderboard'] as List)
              .cast<Map<String, Object?>>();
      expect(lbList.length, 1);
    });
  });
}
