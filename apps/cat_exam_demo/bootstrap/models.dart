import 'package:cat_exam_demo/app/models/candidate.dart';
import 'package:cat_exam_demo/app/models/exam_answer.dart';
import 'package:cat_exam_demo/app/models/exam_question.dart';
import 'package:cat_exam_demo/app/models/exam_session.dart';
import 'package:daravel/daravel.dart';

/// Model registry for CAT Exam application.
final List<ModelDefinition<Model>> models = <ModelDefinition<Model>>[
  Candidate.definition,
  ExamQuestion.definition,
  ExamSession.definition,
  ExamAnswer.definition,
];
