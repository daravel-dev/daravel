import 'package:daravel/daravel.dart';

/// Scheduled tasks: Horizon's metric snapshots every five minutes, for its
/// Metrics tab (`dartisan schedule:work`).
void consoleRoutes(Schedule schedule) {
  schedule.command('horizon:snapshot').everyFiveMinutes();
}
