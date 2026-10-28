import 'package:daravel/daravel.dart';
import 'package:virtual_classroom/app/http/controllers/meeting_controller.dart';

/// API routes, mounted under `/api` by `bootstrap/app.dart`. Every route
/// needs a bearer token (`auth`).
void apiRoutes(Router router) {
  const meetings = MeetingController();
  router.group((router) {
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
