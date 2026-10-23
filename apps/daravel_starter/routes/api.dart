import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/controllers/ping_controller.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`.
void apiRoutes(Router router) {
  final ping = PingController();

  router.get('/ping', ping.ping).name('ping');
  router.get('/users/{id}', ping.showUser).name('users.show');
}
