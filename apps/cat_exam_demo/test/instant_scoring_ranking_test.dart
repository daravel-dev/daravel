import 'dart:io';

import 'package:cat_exam_demo/app/models/candidate.dart';
import 'package:cat_exam_demo/app/models/exam_session.dart';
import 'package:cat_exam_demo/app/services/exam_engine_service.dart';

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

  test('Instant Scoring and BKN Tie-Breaker Ranking Rules', () async {
    // We will test 2 candidates who finish the exam:
    // Candidate 1: Budi Santoso
    // Candidate 2: Siti Rahmawati

    // Candidate 1 login:
    final budiLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201011203950001',
        'exam_number': 'TKA-2026-001',
        'device_id': 'pc_budi',
      },
    );
    final budiToken =
        (budiLogin.json as Map<String, Object?>)['token'] as String;

    // Fetch Budi's questions:
    final budiQResp = await client
        .withToken(budiToken)
        .get('/api/exam/questions');
    final budiQuestions =
        ((budiQResp.json as Map<String, Object?>)['questions'] as List)
            .cast<Map<String, Object?>>();

    // Answer Budi's questions to achieve a specific score:
    // We answer all questions selecting option 'A'
    for (final q in budiQuestions) {
      await client
          .withToken(budiToken)
          .post(
            '/api/exam/answer',
            json: {
              'question_id': q['question_id'],
              'selected_option': 'A',
              'is_doubtful': false,
              'idempotency_key': 'budi_ans_${q['question_id']}',
            },
          );
    }

    final budiFinish = await client
        .withToken(budiToken)
        .post('/api/exam/finish');
    budiFinish.assertOk().assertJsonPath('status', 'submitted');
    final budiData = budiFinish.json as Map<String, Object?>;
    final budiScores = budiData['scores'] as Map<String, Object?>;

    expect(budiScores['total'], isNotNull);
    expect(budiScores['twk_max'], 25);
    expect(budiScores['tiu_max'], 25);
    expect(budiScores['tkp_max'], 25);

    // Verify candidate model status was updated to 'completed':
    final budiModel = await Candidate.where('nik', '3201011203950001').first();
    expect(budiModel?.status, 'completed');

    // Logging in again as Budi immediately returns completed result:
    final budiReLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201011203950001',
        'exam_number': 'TKA-2026-001',
        'device_id': 'pc_budi',
      },
    );
    budiReLogin
        .assertOk()
        .assertJsonPath('status', 'completed')
        .assertJsonPath('message', contains('Your exam is finished'));

    // Candidate 2 login: Siti Rahmawati
    final sitiLogin = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201015508960002',
        'exam_number': 'TKA-2026-002',
        'device_id': 'pc_siti',
      },
    );
    final sitiToken =
        (sitiLogin.json as Map<String, Object?>)['token'] as String;

    final sitiQResp = await client
        .withToken(sitiToken)
        .get('/api/exam/questions');
    final sitiQuestions =
        ((sitiQResp.json as Map<String, Object?>)['questions'] as List)
            .cast<Map<String, Object?>>();

    // Answer Siti's questions selecting option 'B'
    for (final q in sitiQuestions) {
      await client
          .withToken(sitiToken)
          .post(
            '/api/exam/answer',
            json: {
              'question_id': q['question_id'],
              'selected_option': 'B',
              'is_doubtful': false,
              'idempotency_key': 'siti_ans_${q['question_id']}',
            },
          );
    }

    final sitiFinish = await client
        .withToken(sitiToken)
        .post('/api/exam/finish');
    sitiFinish.assertOk().assertJsonPath('status', 'submitted');

    // Check leaderboard: Both candidates appear with distinct ranks 1 and 2
    final lbResp = await client.get('/api/exam/leaderboard');
    lbResp.assertOk().assertJsonPath('total_completed', 2);

    final lbList =
        ((lbResp.json as Map<String, Object?>)['leaderboard'] as List)
            .cast<Map<String, Object?>>();
    expect(lbList.length, 2);
    expect(lbList[0]['rank'], 1);
    expect(lbList[1]['rank'], 2);

    final rank1Total = lbList[0]['total_score'] as int;
    final rank2Total = lbList[1]['total_score'] as int;
    expect(
      rank1Total >= rank2Total,
      isTrue,
      reason: 'Rank 1 must have total score >= Rank 2',
    );
  });

  test('ExamEngineService passing grade logic evaluation', () {
    expect(ExamEngineService.twkPassingGrade, 15);
    expect(ExamEngineService.tiuPassingGrade, 15);
    expect(ExamEngineService.tkpPassingGrade, 18);
  });

  test('BKN PermenPAN-RB Tie-Breaker: TKP > TIU > TWK > SubmittedAt > ID', () {
    final baseTime = DateTime.utc(2026, 11, 1, 9, 0, 0);

    // Rule 1: Higher Total Score wins
    final s1 = ExamSession()
      ..id = 's1'
      ..totalScore = 60
      ..scoreTkp = 20
      ..scoreTiu = 20
      ..scoreTwk = 20
      ..submittedAt = baseTime;
    final s2 = ExamSession()
      ..id = 's2'
      ..totalScore = 55
      ..scoreTkp = 25
      ..scoreTiu = 25
      ..scoreTwk = 5
      ..submittedAt = baseTime;
    expect(
      ExamEngineService.compareSessions(s1, s2),
      lessThan(0),
    ); // s1 finishes before s2

    // Rule 2: Tied Total Score -> Higher TKP wins
    final s3 = ExamSession()
      ..id = 's3'
      ..totalScore = 50
      ..scoreTkp = 25
      ..scoreTiu = 15
      ..scoreTwk = 10
      ..submittedAt = baseTime;
    final s4 = ExamSession()
      ..id = 's4'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 20
      ..scoreTwk = 10
      ..submittedAt = baseTime;
    expect(
      ExamEngineService.compareSessions(s3, s4),
      lessThan(0),
    ); // s3 has higher TKP

    // Rule 3: Tied Total & TKP -> Higher TIU wins
    final s5 = ExamSession()
      ..id = 's5'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 20
      ..scoreTwk = 10
      ..submittedAt = baseTime;
    final s6 = ExamSession()
      ..id = 's6'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime;
    expect(
      ExamEngineService.compareSessions(s5, s6),
      lessThan(0),
    ); // s5 has higher TIU

    // Rule 4: Tied Total, TKP & TIU -> Higher TWK wins
    final s7 = ExamSession()
      ..id = 's7'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime;
    final s8 = ExamSession()
      ..id = 's8'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 10
      ..submittedAt = baseTime;
    expect(
      ExamEngineService.compareSessions(s7, s8),
      lessThan(0),
    ); // s7 has higher TWK

    // Rule 5: Tied all scores -> Earlier submittedAt wins
    final s9 = ExamSession()
      ..id = 's9'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime;
    final s10 = ExamSession()
      ..id = 's10'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime.add(const Duration(seconds: 10));
    expect(
      ExamEngineService.compareSessions(s9, s10),
      lessThan(0),
    ); // s9 submitted 10s earlier

    // Rule 6: Identical timestamp -> Deterministic ID comparison
    final s11 = ExamSession()
      ..id = 'a_sess'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime;
    final s12 = ExamSession()
      ..id = 'b_sess'
      ..totalScore = 50
      ..scoreTkp = 20
      ..scoreTiu = 15
      ..scoreTwk = 15
      ..submittedAt = baseTime;
    expect(ExamEngineService.compareSessions(s11, s12), lessThan(0));
  });
}
