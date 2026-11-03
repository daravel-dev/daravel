import 'package:cat_exam_demo/app/http/controllers/exam_web_controller.dart';
import 'package:daravel/daravel.dart';

/// Web routes for the CAT examination platform.
void webRoutes(Router router) {
  final web = ExamWebController();

  router.get('/', web.index).name('exam.home');
  router.get('/exam', web.index).name('exam.app');
}
