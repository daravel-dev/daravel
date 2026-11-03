import 'package:daravel/daravel.dart';
import 'package:virtual_classroom/app/http/controllers/auth_controller.dart';
import 'package:virtual_classroom/app/http/controllers/demo_controller.dart';
import 'package:virtual_classroom/app/http/controllers/meeting_controller.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`.
void apiRoutes(Router router) {
  const auth = AuthController();
  const demo = DemoController();
  const meetings = MeetingController();

  // Public demo & auth endpoints
  router.post('/auth/login', auth.login).name('auth.login').middleware(const [
    'throttle:login',
  ]);
  router.post('/auth/demo-switch', auth.demoSwitch).name('auth.demo_switch');
  router.get('/demo/state', demo.state).name('demo.state');

  // Authenticated routes (needs bearer token `auth`)
  router.group((router) {
    router.get('/auth/me', auth.me).name('auth.me');
    router.get('/activity-logs', demo.activityLogs).name('activity_logs.index');

    router.get('/meetings', meetings.index).name('meetings.index');
    router
        .post('/classrooms/{classroom}/meetings', meetings.store)
        .name('meetings.store')
        .middleware(const ['role:teacher']);
    router.get('/meetings/{meeting}', meetings.show).name('meetings.show');
    router
        .patch('/meetings/{meeting}', meetings.update)
        .name('meetings.update');
    router
        .delete('/meetings/{meeting}', meetings.destroy)
        .name('meetings.destroy');
    // Everyone joins at the bell: a limit per user keeps a client that
    // retries in a loop from taking the room service's capacity.
    router
        .post('/meetings/{meeting}/join', meetings.join)
        .name('meetings.join')
        .middleware(const ['throttle:join']);
  }, middleware: const ['auth']);
}
