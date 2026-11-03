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

  test('GET / serves CAT HTML web application', () async {
    final response = await client.get('/', headers: {'accept': 'text/html'});
    response.assertOk();
    expect(response.body, contains('<html lang="en">'));
    expect(response.body, contains('CAT DISTRICT ACADEMIC TEST'));
    expect(response.body, contains('locked to one device'));
  });

  test('?lang=id serves the page in Indonesian', () async {
    final response = await client.get(
      '/?lang=id',
      headers: {'accept': 'text/html'},
    );
    response.assertOk();
    expect(response.body, contains('<html lang="id">'));
    expect(response.body, contains('CAT UJIAN TKA KABUPATEN'));
    expect(response.body, contains('Single-Device Lock'));
  });

  test('API messages follow Accept-Language', () async {
    final body = {
      'nik': '0000000000000000',
      'exam_number': 'NONE',
      'device_id': 'pc_x',
    };
    final english = await client.post('/api/exam/verify', json: body);
    expect(english.body, contains('is not registered for this exam'));

    final indonesian = await client.post(
      '/api/exam/verify',
      json: body,
      headers: {'accept-language': 'id'},
    );
    expect(indonesian.body, contains('tidak terdaftar dalam sistem seleksi'));
  });

  test('questions come in the request locale with the same keys', () async {
    final login = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201011203950001',
        'exam_number': 'TKA-2026-001',
        'device_id': 'pc_lang',
      },
    );
    final token = (login.json as Map<String, Object?>)['token'] as String;
    final auth = {'authorization': 'Bearer $token'};

    final english = await client.get('/api/exam/questions', headers: auth);
    final indonesian = await client.get(
      '/api/exam/questions',
      headers: {...auth, 'accept-language': 'id'},
    );
    english.assertOk();
    indonesian.assertOk();
    expect(english.body, contains('VEHICLE : FUEL = HUMAN'));
    expect(indonesian.body, contains('KENDARAAN : BENSIN = MANUSIA'));
  });

  test('Full Candidate Exam Lifecycle: Verify → Questions → Answer → Batch → Finish → Result', () async {
    // 1. Candidate verification with valid NIK & Exam Number
    final verifyResp = await client.post(
      '/api/exam/verify',
      json: {
        'nik': '3201011203950001',
        'exam_number': 'TKA-2026-001',
        'device_id': 'pc_lab_01',
        'duration_minutes': 30,
      },
    );

    verifyResp
        .assertOk()
        .assertJsonPath('status', 'created')
        .assertJsonPath('candidate.name', 'Budi Santoso, S.Kom.');

    final verifyData = verifyResp.json as Map<String, Object?>;
    final token = verifyData['token'] as String;
    final session = verifyData['session'] as Map<String, Object?>;
    final sessionId = session['id'] as String;
    expect(token, startsWith('cat_'));

    // 2. Fetch questions for this candidate
    final qResp = await client.withToken(token).get('/api/exam/questions');
    qResp.assertOk().assertJsonPath('total_questions', 15);

    final qData = qResp.json as Map<String, Object?>;
    final questions = (qData['questions'] as List).cast<Map<String, Object?>>();
    expect(questions.length, 15);

    // CRITICAL SECURITY ASSERTION: correct answers & score weights must NEVER leak to client!
    for (final q in questions) {
      expect(q.containsKey('correct_option'), isFalse);
      final options = (q['options'] as List).cast<Map<String, Object?>>();
      for (final opt in options) {
        expect(opt.containsKey('score'), isFalse);
        expect(opt.containsKey('points'), isFalse);
        expect(opt['id'], isIn(['A', 'B', 'C', 'D', 'E']));
      }
    }

    // 3. Save single answer in real time (Question #1)
    final firstQ = questions.first;
    final firstQId = firstQ['question_id'] as int;

    final ansResp = await client
        .withToken(token)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': firstQId,
            'selected_option': 'C',
            'is_doubtful': false,
            'idempotency_key': 'idem_q1_v1',
          },
        );

    ansResp
        .assertOk()
        .assertJsonPath('status', 'saved')
        .assertJsonPath('question_id', firstQId)
        .assertJsonPath('selected_option', 'C');

    // 4. Batch answer auto-save for questions 2 and 3
    final secondQId = questions[1]['question_id'] as int;
    final thirdQId = questions[2]['question_id'] as int;

    final batchResp = await client
        .withToken(token)
        .post(
          '/api/exam/batch-answers',
          json: {
            'answers': [
              {
                'question_id': secondQId,
                'selected_option': 'B',
                'is_doubtful': true,
                'idempotency_key': 'idem_batch_q2',
              },
              {
                'question_id': thirdQId,
                'selected_option': 'A',
                'is_doubtful': false,
                'idempotency_key': 'idem_batch_q3',
              },
            ],
          },
        );

    batchResp
        .assertOk()
        .assertJsonPath('status', 'batch_saved')
        .assertJsonPath('saved_count', 2);

    // 5. Query active session state
    final sessResp = await client.withToken(token).get('/api/exam/session');
    sessResp
        .assertOk()
        .assertJsonPath('session.id', sessionId)
        .assertJsonPath('session.status', 'active');

    final sessData = sessResp.json as Map<String, Object?>;
    final answersMap = sessData['answers'] as Map;
    expect(answersMap.containsKey('$firstQId'), isTrue);
    expect(answersMap.containsKey('$secondQId'), isTrue);
    expect(answersMap.containsKey('$thirdQId'), isTrue);

    // 6. Finish exam and generate instant score
    final finishResp = await client.withToken(token).post('/api/exam/finish');
    finishResp
        .assertOk()
        .assertJsonPath('status', 'submitted')
        .assertJsonPath('session_id', sessionId);

    final finishData = finishResp.json as Map<String, Object?>;
    final initialSubmittedAt = finishData['submitted_at'] as String;
    final scores = finishData['scores'] as Map<String, Object?>;
    expect(scores.containsKey('twk'), isTrue);
    expect(scores.containsKey('tiu'), isTrue);
    expect(scores.containsKey('tkp'), isTrue);
    expect(scores.containsKey('total'), isTrue);
    expect(scores.containsKey('passing_grade_met'), isTrue);

    // 6b. Idempotency test: calling finish again returns identical result and preserves submitted_at
    final doubleFinishResp = await client
        .withToken(token)
        .post('/api/exam/finish');
    doubleFinishResp
        .assertOk()
        .assertJsonPath('status', 'submitted')
        .assertJsonPath('submitted_at', initialSubmittedAt);

    // 6c. Attempting to answer a question after submission must be rejected
    final postSubmitAnswer = await client
        .withToken(token)
        .post(
          '/api/exam/answer',
          json: {
            'question_id': 1,
            'selected_option': 'A',
            'is_doubtful': false,
            'idempotency_key': 'after_finish_hack',
          },
        );
    postSubmitAnswer.assertStatus(400).assertJsonPath('error', 'EXAM_ERROR');

    // 7. Verify score certificate lookup has consistent ranking schema
    final resultResp = await client.get('/api/exam/result/$sessionId');
    resultResp
        .assertOk()
        .assertJsonPath('session_id', sessionId)
        .assertJsonPath('candidate.name', 'Budi Santoso, S.Kom.')
        .assertJsonPath('ranking.rank', 1)
        .assertJsonPath('ranking.total_participants', 1);

    // 8. Verify public / proctor live ranking leaderboard
    final lbResp = await client.get('/api/exam/leaderboard?limit=10');
    lbResp.assertOk();
    final lbData = lbResp.json as Map<String, Object?>;
    final lbList = (lbData['leaderboard'] as List).cast<Map<String, Object?>>();
    expect(lbList.isNotEmpty, isTrue);
    expect(lbList.first['candidate_name'], 'Budi Santoso, S.Kom.');
  });
}
