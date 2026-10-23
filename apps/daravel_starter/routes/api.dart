import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/controllers/ping_controller.dart';
import 'package:daravel_starter/app/http/controllers/user_controller.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`.
void apiRoutes(Router router) {
  final ping = PingController();
  final users = UserController();

  router.get('/ping', ping.ping).name('ping');
  router.get('/users', users.index).name('users.index');
  router.get('/users/{id}', users.show).name('users.show').whereNumber('id');
  router.post('/users', users.store).name('users.store');
}
