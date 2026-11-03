import 'package:daravel/daravel.dart';

import 'candidate_seeder.dart';
import 'question_seeder.dart';

/// Root seeder for CAT Exam application.
final class DatabaseSeeder extends Seeder {
  const DatabaseSeeder();

  @override
  Future<void> run() async {
    await const CandidateSeeder().run();
    await const QuestionSeeder().run();
  }
}
