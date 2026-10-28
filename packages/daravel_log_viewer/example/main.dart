import 'package:daravel/daravel.dart';
import 'package:daravel_log_viewer/daravel_log_viewer.dart';

/// Logs to `storage/logs/daravel-YYYY-MM-DD.log` and serves the viewer at
/// `/log-viewer` (open in `APP_ENV=local`; give it middleware elsewhere).
/// `GET /boom` logs an error with a stack trace to look at.
Application createApp() =>
    Application.configure(basePath: '.')
        .withEnv({'LOG_STACK': 'console,daily'})
        .withLogViewer()
        .withRouting(
          api: (router) {
            router.get('/boom', (_) {
              try {
                throw StateError('Something broke');
              } on StateError catch (error, stack) {
                Log.error(
                  'Order failed',
                  context: {'order_id': 42, 'password': 'never shown'},
                  error: error,
                  stackTrace: stack,
                );
              }
              return {'logged': true};
            });
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
