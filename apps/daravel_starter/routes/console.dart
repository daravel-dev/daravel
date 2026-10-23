import 'package:daravel/daravel.dart';

/// Scheduled tasks (Laravel 11 `routes/console.php`). Run them with
/// `dartisan schedule:run` (from cron, every minute) or `schedule:work`.
void consoleRoutes(Schedule schedule) {
  // Prune expired personal access tokens nightly.
  schedule
      .call(() async {
        final pruned = await Auth.tokenGuard().pruneExpired();
        Log.info('Pruned $pruned expired access token(s).');
      })
      .named('tokens:prune')
      .dailyAt('03:00')
      .withoutOverlapping();

  // Delete failed jobs older than a week.
  schedule.command('queue:flush', const ['--hours=168']).weekly();
}
