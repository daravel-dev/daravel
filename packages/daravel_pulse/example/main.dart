import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';

/// Serves the dashboard at `/pulse` (open in `APP_ENV=local`; give it
/// middleware elsewhere). `GET /slow` takes 1.2 s and `GET /boom` throws,
/// so both show up on it.
Application createApp() =>
    Application.configure(basePath: '.')
        .withPulse()
        .withRouting(
          api: (router) {
            router
              ..get('/slow', (_) async {
                await Future<void>.delayed(const Duration(milliseconds: 1200));
                return {'slow': true};
              })
              ..get('/boom', (_) => throw StateError('Something broke'));
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
