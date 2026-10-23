import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/controllers/welcome_controller.dart';

/// Web routes (HTML), mounted at the root by `bootstrap/app.dart`.
void webRoutes(Router router) {
  final welcome = WelcomeController();

  router.get('/', welcome.index).name('welcome');
}
