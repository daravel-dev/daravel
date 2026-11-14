import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// `cache:clear [store] [--locks]` — flushes the default (or named) cache
/// store. Its locks stay unless `--locks` is given, as in Laravel, so a
/// clear in production does not hand a held lock to a second holder.
final class CacheClearCommand extends DaravelCommand {
  /// The `dartisan cache:clear` command.
  CacheClearCommand(super.createApp) {
    argParser.addFlag(
      'locks',
      negatable: false,
      help: 'Release every lock of the store too, whoever holds it.',
    );
  }

  @override
  String get name => 'cache:clear';

  @override
  String get description => 'Flush the application cache.';

  @override
  Future<int> run() => withApp((app) async {
    final store = argResults!.rest.isEmpty ? null : argResults!.rest.first;
    final cache = App.make<CacheManager>().store(store);
    await cache.flush();
    final locks = argResults!['locks'] as bool;
    if (locks) {
      await cache.flushLocks();
    }
    stdout.writeln(
      'Application cache ${locks ? 'and locks ' : ''}cleared successfully'
      '${store == null ? '' : ' ($store)'}.',
    );
    return 0;
  });
}

/// `cache:prune-expired [store]`: deletes the expired entries and locks a
/// store keeps until they are read (`database` rows, `file` files). Schedule
/// it (hourly, say) when keys are written once and rarely read again.
final class CachePruneExpiredCommand extends DaravelCommand {
  /// The `dartisan cache:prune-expired` command.
  CachePruneExpiredCommand(super.createApp);

  @override
  String get name => 'cache:prune-expired';

  @override
  String get description =>
      'Delete the expired entries and locks of a cache store.';

  @override
  Future<int> run() => withApp((app) async {
    final store = argResults!.rest.isEmpty ? null : argResults!.rest.first;
    final pruned = await App.make<CacheManager>().store(store).pruneExpired();
    stdout.writeln(
      'Pruned $pruned expired cache entr${pruned == 1 ? 'y' : 'ies'}'
      '${store == null ? '' : ' ($store)'}.',
    );
    return 0;
  });
}

/// `coordinator:stats [--url=http://host:8000/metrics] [--token=...]`: the
/// running server's coordinator, read from its `/metrics`: queue, refused
/// calls, round trips by service (p50/p99) and what to do about them.
/// Without `--url` it shows this process's own coordinator, which only
/// says something inside a long-running command.
final class CoordinatorStatsCommand extends DaravelCommand {
  /// The `dartisan coordinator:stats` command.
  CoordinatorStatsCommand(super.createApp) {
    argParser
      ..addOption(
        'url',
        help:
            "The server's metrics endpoint (METRICS_ENABLED=true), e.g. "
            'http://127.0.0.1:8000/metrics.',
      )
      ..addOption('token', help: 'Its METRICS_TOKEN; the app\'s by default.')
      ..addFlag('json', negatable: false, help: 'Print the raw numbers.');
  }

  @override
  String get name => 'coordinator:stats';

  @override
  String get description =>
      'Show the coordinator queue, round trips and advice.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    final url = results['url'] as String?;
    if (url == null) {
      final channel = App.make<CoordinatorChannel>();
      if (channel is LocalCoordinatorChannel) {
        stdout
          ..writeln(
            const JsonEncoder.withIndent('  ')
                .convert(channel.coordinator.stats()),
          )
          ..writeln(
            "This process's own coordinator; pass --url=<server>/metrics "
            'for the running server.',
          );
      } else {
        stdout.writeln('Pass --url=<server>/metrics for the running server.');
      }
      return 0;
    }
    final token =
        results['token'] as String? ??
        app.config.section<MetricsConfig>().token;
    var request = Http.timeout(const Duration(seconds: 10));
    if (token != null && token.isNotEmpty) {
      request = request.withToken(token);
    }
    final ClientResponse response;
    try {
      response = await request.get(url);
    } on ConnectionException catch (error) {
      stderr.writeln('Cannot reach ${redactUrl(url)}: ${error.message}');
      return 1;
    }
    if (!response.successful) {
      stderr.writeln(
        '${redactUrl(url)} answered ${response.status}'
        '${response.status == 401 ? ': pass --token (METRICS_TOKEN)' : ''}'
        '${response.status == 404 ? ': is METRICS_ENABLED=true?' : ''}.',
      );
      return 1;
    }
    final report = CoordinatorReport.parse(response.body);
    if (results['json'] as bool) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'messages': report.messages,
          'rejected': report.rejected,
          'in_flight': report.inFlight,
          'in_flight_peak': report.inFlightPeak,
          'max_queue': report.maxQueue,
          'calls': {
            for (final MapEntry(:key, :value) in report.calls.entries)
              key: {
                'count': value.count,
                'p50_s': value.quantile(0.5),
                'p99_s': value.quantile(0.99),
                'timeouts': value.timeouts,
              },
          },
          'advice': report.advice(),
        }),
      );
    } else {
      stdout.write(report.render());
    }
    return 0;
  });
}

/// `storage:link [--force]` — creates `public/storage` → `storage/app/public`.
final class StorageLinkCommand extends DaravelCommand {
  /// The `dartisan storage:link` command.
  StorageLinkCommand(super.createApp) {
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Recreate existing symbolic links.',
    );
  }

  @override
  String get name => 'storage:link';

  @override
  String get description =>
      'Create the symbolic links configured for the application.';

  @override
  Future<int> run() => withApp((app) async {
    try {
      final created = await App.make<StorageManager>().link(
        force: argResults!['force'] as bool,
      );
      if (created.isEmpty) {
        stdout.writeln('All links already exist (use --force to recreate).');
      }
      for (final link in created) {
        stdout.writeln('The [$link] link has been connected.');
      }
      return 0;
    } on FileSystemException catch (error) {
      stderr.writeln(
        'Could not create the link: ${error.message}. On Windows enable '
        'Developer Mode or run the terminal as administrator.',
      );
      return 1;
    }
  });
}

/// `static:hash`: hashes the files of every `withStatic` directory and
/// writes their versions to `.static-manifest.json` in it, so a production
/// boot versions them from their size and modification time instead of
/// reading every file. Run it in the deploy step, after the assets are
/// built; a file changed since is hashed again at boot.
final class StaticHashCommand extends DaravelCommand {
  /// The `dartisan static:hash` command.
  StaticHashCommand(super.createApp);

  @override
  String get name => 'static:hash';

  @override
  String get description =>
      'Write the versions of the static files for a faster production boot.';

  @override
  Future<int> run() => withApp((app) async {
    final directories = App.make<StaticAssets>().directories;
    if (directories.isEmpty) {
      stdout.writeln('No static directory is registered (withStatic).');
      return 0;
    }
    for (final files in directories) {
      final target = files.writeManifest();
      stdout.writeln('Hashed ${files.paths.length} file(s) into [$target].');
    }
    return 0;
  });
}
