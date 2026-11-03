import 'package:cat_exam_demo/app/models/exam_question.dart';
import 'package:cat_exam_demo/app/services/question_bank.dart';
import 'package:daravel/daravel.dart';

/// Seeds question bank into the database for persistence.
final class QuestionSeeder extends Seeder {
  const QuestionSeeder();

  @override
  Future<void> run() async {
    for (final q in QuestionBank.defaultQuestions) {
      final existing = await ExamQuestion.find(q.id);
      if (existing == null) {
        await ExamQuestion.create({
          'id': q.id,
          'category': q.category,
          'question_text': q.questionText,
          'options': q.options.map((o) => o.toJson()).toList(),
          'correct_option': q.correctOption,
          'weight': q.weight,
        });
      }
    }
  }
}
