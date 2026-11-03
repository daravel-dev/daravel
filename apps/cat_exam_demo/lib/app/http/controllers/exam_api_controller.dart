import 'dart:math';

import 'package:daravel/daravel.dart';

import '../../models/candidate.dart';
import '../../models/exam_session.dart';
import '../../services/exam_engine_service.dart';
import '../../services/question_bank.dart';

/// REST API Controller for CAT CPNS / TKA Examination Platform.
final class ExamApiController {
  ExamApiController({ExamEngineService? examEngine})
    : _examEngine = examEngine ?? ExamEngineService();

  final ExamEngineService _examEngine;

  /// Helper to extract session token from Authorization header or X-Exam-Token.
  String? _resolveToken(Request request) {
    return request.bearerToken() ?? request.header('x-exam-token');
  }

  /// Verifies candidate credentials, locks device to session, and returns active session.
  ///
  /// POST /api/exam/verify
  Future<Response> verify(Request request) async {
    final input = await request.all();
    final nik = input['nik']?.toString().trim() ?? '';
    final examNumber = input['exam_number']?.toString().trim() ?? '';
    final rawDeviceId = input['device_id']?.toString().trim();
    final deviceId = (rawDeviceId != null && rawDeviceId.isNotEmpty)
        ? rawDeviceId
        : 'browser_${request.ip}_${(request.header('user-agent') ?? 'ua').hashCode}';
    final customDuration = input['duration_minutes'] is int
        ? input['duration_minutes'] as int
        : int.tryParse(input['duration_minutes']?.toString() ?? '');

    if (nik.isEmpty || examNumber.isEmpty) {
      return Response.json({
        'error': 'VALIDATION_ERROR',
        'message': trans('exam.credentials_required'),
      }, status: 422);
    }

    try {
      final result = await _examEngine.verifyCandidateAndLock(
        nik: nik,
        examNumber: examNumber,
        deviceId: deviceId,
        customDurationMinutes: customDuration,
      );

      return Response.json(result, status: 200);
    } on DeviceLockConflictException catch (e) {
      return Response.json({
        'error': 'DEVICE_LOCK_CONFLICT',
        'message': e.message,
        'nik': e.nik,
        'locked_device': e.lockedDeviceId,
        'attempted_device': e.attemptedDeviceId,
      }, status: 409);
    } on DaravelException catch (e) {
      return Response.json({
        'error': 'AUTH_FAILED',
        'message': e.message,
      }, status: 404);
    }
  }

  /// Retrieves the current candidate session status and timer.
  ///
  /// GET /api/exam/session
  Future<Response> session(Request request) async {
    final token = _resolveToken(request);
    if (token == null) {
      return Response.json({
        'error': 'UNAUTHORIZED',
        'message': trans('exam.token_missing'),
      }, status: 401);
    }

    final session = await ExamSession.where('token', token).first();
    if (session == null) {
      return Response.json({
        'error': 'SESSION_NOT_FOUND',
        'message': trans('exam.session_invalid_or_expired'),
      }, status: 401);
    }

    final candidate = await Candidate.find(session.candidateId);
    final answers = await _examEngine.getSessionAnswersMap(session.id);
    final now = Clock.now();
    final remainingSeconds = max(
      0,
      session.expiresAt.difference(now).inSeconds,
    );

    return Response.json({
      'session': {
        'id': session.id,
        'candidate_id': session.candidateId,
        'device_id': session.deviceId,
        'started_at': session.startedAt.toIso8601String(),
        'expires_at': session.expiresAt.toIso8601String(),
        'duration_minutes': session.durationMinutes,
        'remaining_seconds': remainingSeconds,
        'status': session.status,
        'server_now': now.toIso8601String(),
      },
      'candidate': candidate != null
          ? {
              'id': candidate.id,
              'nik': candidate.nik,
              'exam_number': candidate.examNumber,
              'name': candidate.name,
              'status': candidate.status,
            }
          : null,
      'answers': answers,
    });
  }

  /// Returns deterministically randomized questions for the authenticated session.
  ///
  /// GET /api/exam/questions
  Future<Response> questions(Request request) async {
    final token = _resolveToken(request);
    if (token == null) {
      return Response.json({
        'error': 'UNAUTHORIZED',
        'message': trans('exam.token_missing'),
      }, status: 401);
    }

    final session = await ExamSession.where('token', token).first();
    if (session == null) {
      return Response.json({
        'error': 'SESSION_NOT_FOUND',
        'message': trans('exam.session_invalid'),
      }, status: 401);
    }

    final questions = _examEngine.getQuestionsForSession(session);
    return Response.json({
      'session_id': session.id,
      'total_questions': questions.length,
      'questions': questions,
    });
  }

  /// Real-time answer auto-save with atomic idempotency.
  ///
  /// POST /api/exam/answer
  Future<Response> saveAnswer(Request request) async {
    final token = _resolveToken(request);
    if (token == null) {
      return Response.json({
        'error': 'UNAUTHORIZED',
        'message': trans('exam.token_missing'),
      }, status: 401);
    }

    final session = await ExamSession.where('token', token).first();
    if (session == null) {
      return Response.json({
        'error': 'SESSION_NOT_FOUND',
        'message': trans('exam.session_not_found'),
      }, status: 401);
    }

    final input = await request.all();
    final rawQId = input['question_id'];
    final questionId = rawQId is int
        ? rawQId
        : int.tryParse(rawQId?.toString() ?? '') ?? 0;
    final selectedOption =
        input['selected_option']?.toString().trim().toUpperCase() ?? '';
    final isDoubtful =
        input['is_doubtful'] == true || input['is_doubtful'] == 'true';
    final idempotencyKey =
        input['idempotency_key']?.toString().trim() ??
        '${session.id}_${questionId}_${Clock.now().millisecondsSinceEpoch}';

    const validOptions = {'A', 'B', 'C', 'D', 'E'};
    if (questionId <= 0 ||
        questionId > QuestionBank.defaultQuestions.length ||
        !validOptions.contains(selectedOption)) {
      return Response.json({
        'error': 'VALIDATION_ERROR',
        'message': trans('exam.answer_required', {
          'count': QuestionBank.defaultQuestions.length,
        }),
      }, status: 422);
    }

    try {
      final saved = await _examEngine.saveAnswer(
        session: session,
        questionId: questionId,
        selectedOption: selectedOption,
        isDoubtful: isDoubtful,
        idempotencyKey: idempotencyKey,
      );

      return Response.json(saved, status: 200);
    } on ExamExpiredException catch (e) {
      return Response.json({
        'error': 'EXAM_EXPIRED',
        'message': e.message,
      }, status: 410);
    } on ExamException catch (e) {
      return Response.json({
        'error': 'EXAM_ERROR',
        'message': e.message,
      }, status: 400);
    }
  }

  /// High-throughput batch answer synchronization endpoint.
  ///
  /// POST /api/exam/batch-answers
  Future<Response> saveBatchAnswers(Request request) async {
    final token = _resolveToken(request);
    if (token == null) {
      return Response.json({
        'error': 'UNAUTHORIZED',
        'message': trans('exam.token_missing'),
      }, status: 401);
    }

    final session = await ExamSession.where('token', token).first();
    if (session == null) {
      return Response.json({
        'error': 'SESSION_NOT_FOUND',
        'message': trans('exam.session_not_found'),
      }, status: 401);
    }

    final input = await request.all();
    final answersRaw = input['answers'];
    if (answersRaw is! List) {
      return Response.json({
        'error': 'VALIDATION_ERROR',
        'message': trans('exam.answers_array'),
      }, status: 422);
    }

    final answers = answersRaw
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.cast<String, Object?>())
        .toList();

    try {
      final result = await _examEngine.saveBatchAnswers(
        session: session,
        answers: answers,
      );
      return Response.json(result, status: 200);
    } on ExamExpiredException catch (e) {
      return Response.json({
        'error': 'EXAM_EXPIRED',
        'message': e.message,
      }, status: 410);
    } on ExamException catch (e) {
      return Response.json({
        'error': 'EXAM_ERROR',
        'message': e.message,
      }, status: 400);
    }
  }

  /// Finalizes exam and produces instant scoring and rank certificate.
  ///
  /// POST /api/exam/finish
  Future<Response> finish(Request request) async {
    final token = _resolveToken(request);
    if (token == null) {
      return Response.json({
        'error': 'UNAUTHORIZED',
        'message': trans('exam.token_missing'),
      }, status: 401);
    }

    final session = await ExamSession.where('token', token).first();
    if (session == null) {
      return Response.json({
        'error': 'SESSION_NOT_FOUND',
        'message': trans('exam.session_not_found'),
      }, status: 401);
    }

    final result = await _examEngine.finishExam(session);
    return Response.json(result, status: 200);
  }

  /// Retrieves score report and live rank by session ID.
  ///
  /// GET /api/exam/result/{sessionId}
  Future<Response> result(Request request) async {
    final sessionId = request.routeParams['sessionId'];
    if (sessionId == null || sessionId.isEmpty) {
      return Response.json({
        'error': 'NOT_FOUND',
        'message': trans('exam.session_id_required'),
      }, status: 404);
    }

    final session = await ExamSession.find(sessionId);
    if (session == null) {
      return Response.json({
        'error': 'NOT_FOUND',
        'message': trans('exam.session_missing'),
      }, status: 404);
    }

    if (session.status != 'submitted') {
      return Response.json({
        'error': 'EXAM_NOT_SUBMITTED',
        'message': trans('exam.not_submitted'),
      }, status: 400);
    }

    final rankInfo = await _examEngine.computeRankForSession(session);
    if (session.ranking != rankInfo.rank) {
      session.ranking = rankInfo.rank;
      await session.save();
    }

    final candidate = await Candidate.find(session.candidateId);

    return Response.json({
      'session_id': session.id,
      'candidate': candidate != null
          ? {
              'nik': candidate.nik,
              'exam_number': candidate.examNumber,
              'name': candidate.name,
            }
          : null,
      'status': session.status,
      'scores': {
        'twk': session.scoreTwk ?? 0,
        'twk_max': 25,
        'twk_passing_grade': ExamEngineService.twkPassingGrade,
        'twk_passed':
            (session.scoreTwk ?? 0) >= ExamEngineService.twkPassingGrade,
        'tiu': session.scoreTiu ?? 0,
        'tiu_max': 25,
        'tiu_passing_grade': ExamEngineService.tiuPassingGrade,
        'tiu_passed':
            (session.scoreTiu ?? 0) >= ExamEngineService.tiuPassingGrade,
        'tkp': session.scoreTkp ?? 0,
        'tkp_max': 25,
        'tkp_passing_grade': ExamEngineService.tkpPassingGrade,
        'tkp_passed':
            (session.scoreTkp ?? 0) >= ExamEngineService.tkpPassingGrade,
        'total': session.totalScore ?? 0,
        'total_max': 75,
        'passing_grade_met': session.passingGradeMet ?? false,
      },
      'ranking': {
        'rank': rankInfo.rank,
        'total_participants': rankInfo.totalParticipants,
      },
      'submitted_at': session.submittedAt?.toIso8601String(),
    });
  }

  /// Public / Proctor Live Ranking Feed.
  ///
  /// GET /api/exam/leaderboard
  Future<Response> leaderboard(Request request) async {
    final rawLimit = request.query['limit'];
    final limit = int.tryParse(rawLimit ?? '');
    final result = await _examEngine.getLeaderboard(limit: limit);
    return Response.json({
      'total_completed': result.totalCompleted,
      'showing': result.rows.length,
      'leaderboard': result.rows,
      'generated_at': Clock.now().toIso8601String(),
    });
  }

  /// Proctor Admin tool: unlocks candidate's device lock.
  ///
  /// POST /api/exam/proctor/reset-lock
  Future<Response> proctorResetLock(Request request) async {
    final input = await request.all();
    final nik = input['nik']?.toString().trim() ?? '';
    final reason = input['reason']?.toString().trim() ?? 'Hardware failure';

    if (nik.isEmpty) {
      return Response.json({
        'error': 'VALIDATION_ERROR',
        'message': trans('exam.nik_required'),
      }, status: 422);
    }

    try {
      await _examEngine.proctorResetDeviceLock(nik: nik, reason: reason);
      return Response.json({
        'status': 'success',
        'message': trans('exam.device_reset', {'nik': nik}),
      });
    } on DaravelException catch (e) {
      return Response.json({
        'error': 'NOT_FOUND',
        'message': e.message,
      }, status: 404);
    }
  }
}
