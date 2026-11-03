import 'package:daravel/daravel.dart';

import '../database/migrations/m_2026_11_01_000001_create_candidates_table.dart';
import '../database/migrations/m_2026_11_01_000002_create_questions_table.dart';
import '../database/migrations/m_2026_11_01_000003_create_exam_sessions_table.dart';
import '../database/migrations/m_2026_11_01_000004_create_exam_answers_table.dart';

/// Migration registry for CAT Exam application.
final List<Migration> migrations = <Migration>[
  const CreateCacheTable(),
  const CreateCandidatesTable(),
  const CreateQuestionsTable(),
  const CreateExamSessionsTable(),
  const CreateExamAnswersTable(),
];
