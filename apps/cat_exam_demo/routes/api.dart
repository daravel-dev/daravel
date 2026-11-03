import 'package:cat_exam_demo/app/http/controllers/exam_api_controller.dart';
import 'package:daravel/daravel.dart';

/// API routes for CAT CPNS / TKA examination platform.
void apiRoutes(Router router) {
  final api = ExamApiController();

  // Candidate authentication & single-device exam lock
  router.post('/exam/verify', api.verify).name('exam.verify');

  // Active session and timer verification
  router.get('/exam/session', api.session).name('exam.session');

  // Question delivery (randomized & sanitized)
  router.get('/exam/questions', api.questions).name('exam.questions');

  // Real-time answer auto-save (atomic & idempotent)
  router.post('/exam/answer', api.saveAnswer).name('exam.answer');

  // Batch sync endpoint for offline recovery / bulk submission
  router
      .post('/exam/batch-answers', api.saveBatchAnswers)
      .name('exam.batch_answers');

  // Instant scoring and submission
  router.post('/exam/finish', api.finish).name('exam.finish');

  // Score certificate and result lookup
  router.get('/exam/result/{sessionId}', api.result).name('exam.result');

  // Live ranking leaderboard feed
  router.get('/exam/leaderboard', api.leaderboard).name('exam.leaderboard');

  // Proctor administration: single-device lock reset
  router
      .post('/exam/proctor/reset-lock', api.proctorResetLock)
      .name('exam.proctor.reset_lock');
}
