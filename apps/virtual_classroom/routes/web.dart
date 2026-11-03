import 'package:daravel/daravel.dart';

import 'package:virtual_classroom/app/http/controllers/classroom_web_controller.dart';

/// Web routes serving the interactive Virtual Classroom client.
void webRoutes(Router router) {
  const web = ClassroomWebController();

  router.get('/', web.index).name('classroom.home');
}
