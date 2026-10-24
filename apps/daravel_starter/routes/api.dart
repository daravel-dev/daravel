import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/controllers/auth_controller.dart';
import 'package:daravel_starter/app/http/controllers/ping_controller.dart';
import 'package:daravel_starter/app/http/controllers/user_controller.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/http/resources/user_resource.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`.
void apiRoutes(Router router) {
  final ping = PingController();
  final users = UserController();
  final auth = AuthController();

  router.get('/ping', ping.ping).name('ping');

  router.post('/auth/register', auth.register).name('auth.register').middleware(
    const ['throttle:register'],
  );
  router.post('/auth/login', auth.login).name('auth.login').middleware(const [
    'throttle:login',
  ]);
  router.group((router) {
    router.get('/auth/me', auth.me).name('auth.me');
    router.post('/auth/logout', auth.logout).name('auth.logout');
  }, middleware: const ['auth']);

  router
      .get('/users', users.index)
      .name('users.index')
      .returns(UserResource.schema, name: 'User', shape: .paginated)
      .action('UserController@index');
  router
      .get('/users/{id}', users.show)
      .name('users.show')
      .whereNumber('id')
      .returns(UserResource.schema, name: 'User')
      .action('UserController@show');
  router
      .post('/users', users.store)
      .name('users.store')
      .validates(const StoreUserRequest())
      .returns(UserResource.schema, name: 'User')
      .action('UserController@store');
  router
      .patch('/users/{id}', users.update)
      .name('users.update')
      .whereNumber('id')
      .middleware(const ['auth']);
}
