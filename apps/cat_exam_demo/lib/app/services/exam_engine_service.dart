import 'dart:math';

import 'package:daravel/daravel.dart';

import '../models/candidate.dart';
import '../models/exam_answer.dart';
import '../models/exam_session.dart';
import 'question_bank.dart';

/// Base exception for CAT examination system.
class ExamException extends DaravelException {
  const ExamException(super.message);
}

/// Exception thrown when a candidate attempts concurrent login from a different device.
final class DeviceLockConflictException extends ExamException {
  DeviceLockConflictException({
    required this.nik,
    required this.lockedDeviceId,
    required this.attemptedDeviceId,
  }) : super(
         trans('exam.device_locked', {'nik': nik, 'device': lockedDeviceId}),
       );

  final String nik;
  final String lockedDeviceId;
  final String attemptedDeviceId;
}

/// Exception thrown when exam timer has expired.
final class ExamExpiredException extends ExamException {
  ExamExpiredException(super.message);
}

/// Service governing the CAT CPNS / TKA Examination Engine.
///
/// Features:
/// - Single-device exam lock (anti-joki / anti concurrent login).
/// - Deterministic question & option randomization per candidate.
/// - Real-time answer auto-save with atomic idempotency and concurrency protection.
/// - Server-side timer validation (tamper-proof).
/// - Instant scoring (TWK, TIU, TKP) and BKN-standard live ranking calculation.
class ExamEngineService {
  ExamEngineService({int? durationMinutes, int? gracePeriodSeconds})
    : durationMinutes =
          durationMinutes ??
          App.tryMake<Env>()?.integer('EXAM_DURATION_MINUTES', 30) ??
          30,
      gracePeriodSeconds =
          gracePeriodSeconds ??
          App.tryMake<Env>()?.integer('EXAM_GRACE_PERIOD_SECONDS', 15) ??
          15;

  final int durationMinutes;
  final int gracePeriodSeconds;

  /// Passing grade thresholds for the 15-question TKA evaluation demo.
  /// (TWK: 5 q * 5 pts = 25 max; TIU: 5 q * 5 pts = 25 max; TKP: 5 q * 5 pts = 25 max; Total: 75 max).
  static const int twkPassingGrade = 15;
  static const int tiuPassingGrade = 15;
  static const int tkpPassingGrade = 18;

  /// Verifies candidate credentials, enforces single-device exam lock, and
  /// creates or resumes an active exam session.
  Future<Map<String, Object?>> verifyCandidateAndLock({
    required String nik,
    required String examNumber,
    required String deviceId,
    int? customDurationMinutes,
  }) async {
    final cleanDeviceId = deviceId.trim();
    if (cleanDeviceId.isEmpty) {
      throw ExamException(trans('exam.invalid_device'));
    }

    final candidate = await Candidate.where(
      'nik',
      nik.trim(),
    ).where('exam_number', examNumber.trim()).first();

    if (candidate == null) {
      throw ExamException(
        trans('exam.not_registered', {'nik': nik, 'number': examNumber}),
      );
    }

    // 1. If candidate has already completed their exam, return completed status.
    if (candidate.status == 'completed') {
      final lastSession = await ExamSession.where(
        'candidate_id',
        candidate.id,
      ).orderBy('created_at', 'desc').first();

      return {
        'status': 'completed',
        'message': trans('exam.completed'),
        'candidate': _candidateToJson(candidate),
        'session': lastSession != null ? _sessionToJson(lastSession) : null,
      };
    }

    // 2. Check for an active session & enforce Single-Device Exam Lock.
    if (candidate.activeSessionId != null) {
      final activeSession = await ExamSession.find(candidate.activeSessionId!);

      if (activeSession != null) {
        if (activeSession.status == 'submitted') {
          candidate.status = 'completed';
          await candidate.save();
          return {
            'status': 'completed',
            'message': trans('exam.completed'),
            'candidate': _candidateToJson(candidate),
            'session': _sessionToJson(activeSession),
          };
        }

        if (activeSession.status == 'expired') {
          final finishResult = await finishExam(activeSession);
          return {
            'status': 'completed',
            'message': trans('exam.time_up_submitted'),
            'candidate': _candidateToJson(candidate),
            'session': _sessionToJson(activeSession),
            'result': finishResult,
          };
        }

        if (activeSession.status == 'active') {
          final now = Clock.now();
          final graceDeadline = activeSession.expiresAt.add(
            Duration(seconds: gracePeriodSeconds),
          );

          // Check if session has naturally expired on the server:
          if (now.isAfter(graceDeadline)) {
            // Auto-finalize expired session
            final finishResult = await finishExam(activeSession);
            return {
              'status': 'completed',
              'message': trans('exam.time_up_submitted'),
              'candidate': _candidateToJson(candidate),
              'session': _sessionToJson(activeSession),
              'result': finishResult,
            };
          }

          // Single-device check:
          if (candidate.deviceId != null &&
              candidate.deviceId != cleanDeviceId) {
            throw DeviceLockConflictException(
              nik: candidate.nik,
              lockedDeviceId: candidate.deviceId!,
              attemptedDeviceId: cleanDeviceId,
            );
          }

          // Bind lock to this device if previously cleared by proctor or first bind:
          if (candidate.deviceId == null ||
              candidate.deviceId != cleanDeviceId) {
            candidate.deviceId = cleanDeviceId;
            await candidate.save();
            activeSession.deviceId = cleanDeviceId;
            await activeSession.save();
          }

          // Device matches: seamless session resumption (e.g. browser refreshed)
          final answers = await getSessionAnswersMap(activeSession.id);
          return {
            'status': 'resumed',
            'message': trans('exam.resumed'),
            'token': activeSession.token,
            'candidate': _candidateToJson(candidate),
            'session': _sessionToJson(activeSession),
            'answers': answers,
          };
        }
      }
    }

    // 3. Start a fresh exam session.
    final duration = customDurationMinutes ?? durationMinutes;
    final startedAt = Clock.now();
    final expiresAt = startedAt.add(Duration(minutes: duration));
    final sessionId = 'sess_${KeyGenerator.ulid(startedAt)}';
    final token = 'cat_${KeyGenerator.ulid()}_${KeyGenerator.ulid()}';
    final seed = Random().nextInt(999999) + 1;

    final session = await ExamSession.create({
      'id': sessionId,
      'candidate_id': candidate.id,
      'device_id': cleanDeviceId,
      'token': token,
      'started_at': startedAt,
      'duration_minutes': duration,
      'expires_at': expiresAt,
      'status': 'active',
      'seed': seed,
    });

    candidate.deviceId = cleanDeviceId;
    candidate.activeSessionId = sessionId;
    candidate.status = 'in_progress';
    await candidate.save();

    return {
      'status': 'created',
      'message': trans('exam.created'),
      'token': token,
      'candidate': _candidateToJson(candidate),
      'session': _sessionToJson(session),
      'answers': <String, Map<String, Object?>>{},
    };
  }

  /// Proctor tool: resets a candidate's device lock in case of computer hardware
  /// failure at the exam site, allowing them to resume on a replacement PC.
  Future<bool> proctorResetDeviceLock({
    required String nik,
    required String reason,
  }) async {
    final candidate = await Candidate.where('nik', nik.trim()).first();
    if (candidate == null) {
      throw ExamException(trans('exam.candidate_not_found', {'nik': nik}));
    }

    candidate.deviceId = null;
    await candidate.save();
    return true;
  }

  /// Delivers deterministically randomized questions for this candidate's session.
  ///
  /// CRITICAL SECURITY:
  /// - Strips out correct answers and score weights so client DevTools cannot peek.
  /// - Shuffles question order deterministically using session.seed.
  /// - Shuffles options per question deterministically, relabeling them 'A'..'E'.
  List<Map<String, Object?>> getQuestionsForSession(ExamSession session) {
    final masterList = List<QuestionData>.from(QuestionBank.defaultQuestions);

    // 1. Deterministic question shuffle
    final qRandom = Random(session.seed);
    masterList.shuffle(qRandom);

    // 2. Deterministic option shuffle per question
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < masterList.length; i++) {
      final q = masterList[i];
      final optRandom = Random(session.seed ^ q.id);
      final shuffledOpts = List<OptionData>.from(q.options)..shuffle(optRandom);

      const labels = ['A', 'B', 'C', 'D', 'E'];
      final publicOptions = <Map<String, Object?>>[];

      for (var oIdx = 0; oIdx < shuffledOpts.length; oIdx++) {
        final opt = shuffledOpts[oIdx];
        final label = oIdx < labels.length ? labels[oIdx] : 'O$oIdx';
        publicOptions.add({
          'id': label, // Display letter 'A'..'E'
          'text': opt.text,
        });
      }

      result.add({
        'number': i + 1,
        'question_id': q.id,
        'category': q.category,
        'question_text': q.questionText,
        'options': publicOptions,
      });
    }

    return result;
  }

  /// Real-time answer auto-save with atomic idempotency and concurrency protection.
  ///
  /// High throughput:
  /// - Validates server-side exam timer.
  /// - Upserts answer atomically without duplicating records.
  /// - Handles high-frequency auto-saves from thousands of candidates.
  Future<Map<String, Object?>> saveAnswer({
    required ExamSession session,
    required int questionId,
    required String selectedOption,
    required bool isDoubtful,
    required String idempotencyKey,
  }) async {
    final now = Clock.now();
    final graceDeadline = session.expiresAt.add(
      Duration(seconds: gracePeriodSeconds),
    );

    if (session.status == 'submitted') {
      throw ExamException(trans('exam.already_submitted'));
    }

    if (now.isAfter(graceDeadline) || session.status != 'active') {
      if (session.status == 'active') {
        session.status = 'expired';
        await session.save();
      }
      throw ExamExpiredException(
        trans('exam.expired_at', {'time': session.expiresAt.toIso8601String()}),
      );
    }

    final normalizedOption = selectedOption.trim().toUpperCase();
    const validOptions = {'A', 'B', 'C', 'D', 'E'};
    if (!validOptions.contains(normalizedOption)) {
      throw ExamException(
        trans('exam.invalid_option', {'option': selectedOption}),
      );
    }

    if (questionId <= 0 || questionId > QuestionBank.defaultQuestions.length) {
      throw ExamException(
        trans('exam.unknown_question', {
          'id': questionId,
          'count': QuestionBank.defaultQuestions.length,
        }),
      );
    }

    // 2. Check for existing answer for this question in this session:
    var answer = await ExamAnswer.where(
      'session_id',
      session.id,
    ).where('question_id', questionId).first();

    if (answer != null) {
      answer.selectedOption = normalizedOption;
      answer.isDoubtful = isDoubtful;
      answer.idempotencyKey = idempotencyKey;
      answer.answeredAt = now;
      await answer.save();
    } else {
      try {
        answer = await ExamAnswer.create({
          'session_id': session.id,
          'candidate_id': session.candidateId,
          'question_id': questionId,
          'selected_option': normalizedOption,
          'is_doubtful': isDoubtful,
          'idempotency_key': idempotencyKey,
          'answered_at': now,
        });
      } on UniqueConstraintViolationException {
        // Parallel concurrent request inserted this question row first: update it
        answer = await ExamAnswer.where(
          'session_id',
          session.id,
        ).where('question_id', questionId).first();
        if (answer != null) {
          answer.selectedOption = normalizedOption;
          answer.isDoubtful = isDoubtful;
          answer.idempotencyKey = idempotencyKey;
          answer.answeredAt = now;
          await answer.save();
        }
      }
    }

    return {
      'status': 'saved',
      'question_id': questionId,
      'selected_option': normalizedOption,
      'is_doubtful': isDoubtful,
      'idempotency_key': idempotencyKey,
      'server_time': now.toIso8601String(),
    };
  }

  /// High-throughput batch save endpoint for candidates recovering from network blips.
  Future<Map<String, Object?>> saveBatchAnswers({
    required ExamSession session,
    required List<Map<String, Object?>> answers,
  }) async {
    final now = Clock.now();
    final graceDeadline = session.expiresAt.add(
      Duration(seconds: gracePeriodSeconds),
    );

    if (session.status == 'submitted') {
      throw ExamException(trans('exam.batch_submitted'));
    }

    if (now.isAfter(graceDeadline) || session.status != 'active') {
      if (session.status == 'active') {
        session.status = 'expired';
        await session.save();
      }
      throw ExamExpiredException(trans('exam.batch_expired'));
    }

    var savedCount = 0;
    const validOptions = {'A', 'B', 'C', 'D', 'E'};

    for (final item in answers) {
      final rawQId = item['question_id'];
      final qId = rawQId is int
          ? rawQId
          : int.tryParse(rawQId?.toString() ?? '');
      final opt =
          item['selected_option']?.toString().trim().toUpperCase() ?? '';
      final isDoubtful =
          item['is_doubtful'] == true || item['is_doubtful'] == 'true';
      final idem = item['idempotency_key']?.toString().trim() ?? '';

      if (qId == null ||
          qId <= 0 ||
          qId > QuestionBank.defaultQuestions.length ||
          !validOptions.contains(opt)) {
        continue;
      }

      await saveAnswer(
        session: session,
        questionId: qId,
        selectedOption: opt,
        isDoubtful: isDoubtful,
        idempotencyKey: idem.isNotEmpty
            ? idem
            : '${session.id}_${qId}_${now.millisecondsSinceEpoch}',
      );
      savedCount++;
    }

    return {
      'status': 'batch_saved',
      'saved_count': savedCount,
      'server_time': now.toIso8601String(),
    };
  }

  /// Finalizes the exam session, grades all questions, computes live rankings,
  /// and returns the official CAT score breakdown.
  Future<Map<String, Object?>> finishExam(ExamSession session) async {
    final now = Clock.now();
    final candidate = await Candidate.find(session.candidateId);

    // IDEMPOTENCY CHECK: If already submitted, return existing scores without mutating timestamp
    if (session.status == 'submitted') {
      final rankInfo = await computeRankForSession(session);
      return {
        'status': 'submitted',
        'candidate': candidate != null ? _candidateToJson(candidate) : null,
        'session_id': session.id,
        'submitted_at': (session.submittedAt ?? now).toUtc().toIso8601String(),
        'scores': {
          'twk': session.scoreTwk ?? 0,
          'twk_max': 25,
          'twk_passing_grade': twkPassingGrade,
          'twk_passed': (session.scoreTwk ?? 0) >= twkPassingGrade,
          'tiu': session.scoreTiu ?? 0,
          'tiu_max': 25,
          'tiu_passing_grade': tiuPassingGrade,
          'tiu_passed': (session.scoreTiu ?? 0) >= tiuPassingGrade,
          'tkp': session.scoreTkp ?? 0,
          'tkp_max': 25,
          'tkp_passing_grade': tkpPassingGrade,
          'tkp_passed': (session.scoreTkp ?? 0) >= tkpPassingGrade,
          'total': session.totalScore ?? 0,
          'total_max': 75,
          'passing_grade_met': session.passingGradeMet ?? false,
        },
        'ranking': {
          'rank': rankInfo.rank,
          'total_participants': rankInfo.totalParticipants,
        },
      };
    }

    // 1. Load all candidate's answers for this session:
    final answers = await ExamAnswer.where('session_id', session.id).get();
    final answerMap = <int, ExamAnswer>{};
    for (final a in answers) {
      answerMap[a.questionId] = a;
    }

    // 2. Score calculation across TWK, TIU, and TKP:
    var twkScore = 0;
    var tiuScore = 0;
    var tkpScore = 0;

    const labels = ['A', 'B', 'C', 'D', 'E'];

    for (final q in QuestionBank.defaultQuestions) {
      final userAns = answerMap[q.id];
      if (userAns == null) continue; // Unanswered questions get 0 points

      // Reconstruct deterministic option permutation to find original score:
      final optRandom = Random(session.seed ^ q.id);
      final shuffledOpts = List<OptionData>.from(q.options)..shuffle(optRandom);

      final selectedLabel = userAns.selectedOption.toUpperCase();
      final selectedIndex = labels.indexOf(selectedLabel);

      if (selectedIndex >= 0 && selectedIndex < shuffledOpts.length) {
        final chosenOption = shuffledOpts[selectedIndex];

        if (q.category == 'TWK') {
          twkScore += chosenOption.score;
        } else if (q.category == 'TIU') {
          tiuScore += chosenOption.score;
        } else if (q.category == 'TKP') {
          tkpScore += chosenOption.score;
        }
      }
    }

    final totalScore = twkScore + tiuScore + tkpScore;
    final passingGradeMet =
        twkScore >= twkPassingGrade &&
        tiuScore >= tiuPassingGrade &&
        tkpScore >= tkpPassingGrade;

    // Submission time cannot exceed deadline + grace; if expiring naturally, cap at deadline:
    final rawSubmitted = now.isAfter(session.expiresAt)
        ? session.expiresAt
        : now;
    final effectiveSubmittedAt = DateTime.utc(
      rawSubmitted.toUtc().year,
      rawSubmitted.toUtc().month,
      rawSubmitted.toUtc().day,
      rawSubmitted.toUtc().hour,
      rawSubmitted.toUtc().minute,
      rawSubmitted.toUtc().second,
    );

    // 3. Update session record:
    session.scoreTwk = twkScore;
    session.scoreTiu = tiuScore;
    session.scoreTkp = tkpScore;
    session.totalScore = totalScore;
    session.passingGradeMet = passingGradeMet;
    session.status = 'submitted';
    session.submittedAt = effectiveSubmittedAt;
    await session.save();

    // 4. Update candidate status:
    if (candidate != null) {
      candidate.status = 'completed';
      await candidate.save();
    }

    // 5. Calculate real-time rank:
    final rankInfo = await computeRankForSession(session);
    session.ranking = rankInfo.rank;
    await session.save();

    return {
      'status': 'submitted',
      'candidate': candidate != null ? _candidateToJson(candidate) : null,
      'session_id': session.id,
      'submitted_at': effectiveSubmittedAt.toIso8601String(),
      'scores': {
        'twk': twkScore,
        'twk_max': 25,
        'twk_passing_grade': twkPassingGrade,
        'twk_passed': twkScore >= twkPassingGrade,
        'tiu': tiuScore,
        'tiu_max': 25,
        'tiu_passing_grade': tiuPassingGrade,
        'tiu_passed': tiuScore >= tiuPassingGrade,
        'tkp': tkpScore,
        'tkp_max': 25,
        'tkp_passing_grade': tkpPassingGrade,
        'tkp_passed': tkpScore >= tkpPassingGrade,
        'total': totalScore,
        'total_max': 75,
        'passing_grade_met': passingGradeMet,
      },
      'ranking': {
        'rank': rankInfo.rank,
        'total_participants': rankInfo.totalParticipants,
      },
    };
  }

  /// Consolidated BKN / PermenPAN-RB comparator for deterministic tie-breaking:
  /// 1. Total Score DESC
  /// 2. TKP Score DESC
  /// 3. TIU Score DESC
  /// 4. TWK Score DESC
  /// 5. Submitted At ASC
  /// 6. Session ID ASC (stable tie-breaker fallback)
  static int compareSessions(ExamSession a, ExamSession b) {
    final totalA = a.totalScore ?? 0;
    final totalB = b.totalScore ?? 0;
    if (totalA != totalB) return totalB.compareTo(totalA);

    final tkpA = a.scoreTkp ?? 0;
    final tkpB = b.scoreTkp ?? 0;
    if (tkpA != tkpB) return tkpB.compareTo(tkpA);

    final tiuA = a.scoreTiu ?? 0;
    final tiuB = b.scoreTiu ?? 0;
    if (tiuA != tiuB) return tiuB.compareTo(tiuA);

    final twkA = a.scoreTwk ?? 0;
    final twkB = b.scoreTwk ?? 0;
    if (twkA != twkB) return twkB.compareTo(twkA);

    final subA = a.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final subB = b.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final subCmp = subA.compareTo(subB);
    if (subCmp != 0) return subCmp;

    return a.id.compareTo(b.id);
  }

  /// Calculates real-time ranking using standard BKN / PermenPAN-RB tie-breaking rules.
  Future<({int rank, int totalParticipants})> computeRankForSession(
    ExamSession target,
  ) async {
    final allSessions = await ExamSession.where('status', 'submitted').get();
    if (allSessions.isEmpty) return (rank: 1, totalParticipants: 0);

    final sorted = allSessions.toList()..sort(compareSessions);

    var rank = 1;
    for (var i = 0; i < sorted.length; i++) {
      if (sorted[i].id == target.id) {
        rank = i + 1;
        break;
      }
    }

    return (rank: rank, totalParticipants: sorted.length);
  }

  /// Retrieves the public live ranking leaderboard for proctors and monitors.
  Future<({List<Map<String, Object?>> rows, int totalCompleted})>
  getLeaderboard({int? limit}) async {
    final sessions = await ExamSession.where('status', 'submitted').get();
    if (sessions.isEmpty) {
      return (rows: const <Map<String, Object?>>[], totalCompleted: 0);
    }

    final totalCompleted = sessions.length;
    final sorted = sessions.toList()..sort(compareSessions);
    final displayList = (limit != null && limit > 0)
        ? sorted.take(limit).toList()
        : sorted;

    final candidateIds = displayList.map((s) => s.candidateId).toSet().toList();
    final candidates = await Candidate.whereIn('id', candidateIds).get();
    final candidateMap = {for (final c in candidates) c.id: c};

    final result = <Map<String, Object?>>[];
    for (var i = 0; i < displayList.length; i++) {
      final s = displayList[i];
      final c = candidateMap[s.candidateId];

      final maskedNik = c != null && c.nik.length >= 8
          ? '${c.nik.substring(0, 6)}******${c.nik.substring(c.nik.length - 4)}'
          : '***';

      result.add({
        'rank': i + 1,
        'exam_number': c?.examNumber ?? '-',
        'candidate_name':
            c?.name ?? trans('exam.candidate_fallback', {'id': s.candidateId}),
        'masked_nik': maskedNik,
        'score_twk': s.scoreTwk ?? 0,
        'score_tiu': s.scoreTiu ?? 0,
        'score_tkp': s.scoreTkp ?? 0,
        'total_score': s.totalScore ?? 0,
        'passing_grade_met': s.passingGradeMet ?? false,
        'submitted_at': s.submittedAt?.toIso8601String() ?? '-',
      });
    }

    return (rows: result, totalCompleted: totalCompleted);
  }

  /// Maps candidate's existing answers into a fast lookup map for session resumption.
  Future<Map<String, Map<String, Object?>>> getSessionAnswersMap(
    String sessionId,
  ) async {
    final answers = await ExamAnswer.where('session_id', sessionId).get();
    final map = <String, Map<String, Object?>>{};
    for (final a in answers) {
      map['${a.questionId}'] = {
        'selected_option': a.selectedOption,
        'is_doubtful': a.isDoubtful,
        'answered_at': a.answeredAt?.toIso8601String(),
      };
    }
    return map;
  }

  Map<String, Object?> _candidateToJson(Candidate c) => {
    'id': c.id,
    'nik': c.nik,
    'exam_number': c.examNumber,
    'name': c.name,
    'status': c.status,
  };

  Map<String, Object?> _sessionToJson(ExamSession s) {
    final now = Clock.now();
    final remainingSeconds = max(0, s.expiresAt.difference(now).inSeconds);

    return {
      'id': s.id,
      'device_id': s.deviceId,
      'started_at': s.startedAt.toIso8601String(),
      'expires_at': s.expiresAt.toIso8601String(),
      'duration_minutes': s.durationMinutes,
      'remaining_seconds': remainingSeconds,
      'status': s.status,
      'server_now': now.toIso8601String(),
    };
  }
}
