import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'activity.dart';
import 'activity_log.dart';

/// The `activitylog:*` commands, for `bootstrap/commands.dart`.
const List<CommandFactory> activitylogCommands = [ActivitylogCleanCommand.new];

/// `activitylog:clean [log] [--days=N] [--force]` (Spatie's): deletes the
/// activities older than `--days` (`ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS`,
/// 365 by default), of one log when [log] is given.
///
/// Schedule it daily: `schedule.command('activitylog:clean').daily()`.
final class ActivitylogCleanCommand extends DaravelCommand {
  ActivitylogCleanCommand(super.createApp) {
    argParser
      ..addOption(
        'days',
        help: 'Records older than this number of days are deleted.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Required when APP_ENV=production.',
      );
  }

  @override
  String get name => 'activitylog:clean';

  @override
  String get description => 'Clean up old records from the activity log.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    if (app.config.section<AppConfig>().isProduction &&
        !(results['force'] as bool)) {
      stderr.writeln(
        'activitylog:clean deletes records; pass --force to run it in '
        'production.',
      );
      return 1;
    }
    final log = results.rest.firstOrNull;
    final daysOption = results['days'] as String?;
    final days = daysOption == null
        ? ActivityLog.config.deleteRecordsOlderThanDays
        : int.tryParse(daysOption);
    if (days == null) {
      stderr.writeln('The days option must be an integer.');
      return 1;
    }
    stdout.writeln('Cleaning activity log...');
    // Laravel's format, the one both frameworks write in this table.
    final cutoff = formatDateTime(Clock.now().subtract(Duration(days: days)));
    var query = Activity.query().where('created_at', '<', cutoff);
    if (log != null) {
      query = query.inLog(log);
    }
    final deleted = await query.delete();
    stdout
      ..writeln('Deleted $deleted record(s) from the activity log.')
      ..writeln('All done!');
    return 0;
  });
}
