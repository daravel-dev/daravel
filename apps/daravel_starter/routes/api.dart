import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/controllers/auth_controller.dart';
import 'package:daravel_starter/app/http/controllers/ping_controller.dart';
import 'package:daravel_starter/app/http/controllers/user_controller.dart';
import 'package:daravel_starter/app/http/requests/login_request.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';
import 'package:daravel_starter/app/http/resources/user_resource.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`.
void apiRoutes(Router router) {
  final ping = PingController();
  final users = UserController();
  final auth = AuthController();

  router.get('/ping', ping.ping).name('ping');

  router
      .postValidated('/auth/register', const StoreUserRequest(), auth.register)
      .name('auth.register')
      .middleware([Mw.throttle('register')])
      .returns(AuthController.tokenSchema, name: 'AuthToken', shape: .raw)
      .action('AuthController@register');
  router
      .postValidated('/auth/login', const LoginRequest(), auth.login)
      .name('auth.login')
      .middleware([Mw.throttle('login')])
      .returns(
        AuthController.tokenSchema,
        name: 'AuthToken',
        shape: .raw,
        status: 200,
      )
      .action('AuthController@login');
  router.group((router) {
    router
        .get('/auth/me', auth.me)
        .name('auth.me')
        .returns(UserResource.schema, name: 'User')
        .action('AuthController@me');
    router
        .post('/auth/logout', auth.logout)
        .name('auth.logout')
        .returns(const <String, Object?>{}, status: 204)
        .action('AuthController@logout');
  }, middleware: [Mw.auth()]);

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
      .postValidated('/users', const StoreUserRequest(), users.store)
      .name('users.store')
      .returns(UserResource.schema, name: 'User')
      .action('UserController@store');
  router
      .patch('/users/{id}', users.update)
      .name('users.update')
      .whereNumber('id')
      .middleware([Mw.auth()]);
}
