import 'package:daravel/daravel.dart';

/// Scheduled tasks for CAT exam platform.
void consoleRoutes(Schedule schedule) {
  // Prune expired or stale cache locks
  schedule
      .call(() async {
        Log.info('Checking exam sessions consistency...');
      })
      .named('exam:health')
      .hourly();
}
