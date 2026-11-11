import 'package:daravel/daravel.dart';
import 'package:horizon_demo/jobs/demo_jobs.dart';

/// Web routes: a page pointing at the dashboard, and `POST /demo/dispatch`
/// to fill the queues.
void webRoutes(Router router) {
  router
    ..get(
      '/',
      (Request request) => Response.html(
        '<!doctype html><title>Horizon demo</title>'
        '<p>Open <a href="/horizon">/horizon</a>. Dispatch jobs with '
        '<code>POST /demo/dispatch?count=20</code>.</p>',
      ),
    )
    ..post('/demo/dispatch', (Request request) async {
      final count = (int.tryParse(request.query['count'] ?? '') ?? 10).clamp(
        1,
        1000,
      );
      for (var i = 0; i < count; i++) {
        await Queue.push(QuickJob(i), queue: 'default');
        if (i % 5 == 0) {
          await Queue.push(const SlowJob(500), queue: 'reports');
        }
        if (i % 10 == 0) {
          await Queue.push(const FlakyJob(), queue: 'default');
        }
      }
      return Response.json({'dispatched': count});
    });
}
