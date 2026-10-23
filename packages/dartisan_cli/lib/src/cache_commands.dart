import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// `cache:clear [store]` — flushes the default (or named) cache store.
final class CacheClearCommand extends DaravelCommand {
  CacheClearCommand(super.createApp);

  @override
  String get name => 'cache:clear';

  @override
  String get description => 'Flush the application cache.';

  @override
  Future<int> run() => withApp((app) async {
    final store = argResults!.rest.isEmpty ? null : argResults!.rest.first;
    await App.make<CacheManager>().store(store).flush();
    stdout.writeln(
      'Application cache cleared successfully'
      '${store == null ? '' : ' ($store)'}.',
    );
    return 0;
  });
}

/// `coordinator:stats` — snapshot of the in-process coordinator services.
final class CoordinatorStatsCommand extends DaravelCommand {
  CoordinatorStatsCommand(super.createApp);

  @override
  String get name => 'coordinator:stats';

  @override
  String get description =>
      'Show coordinator service statistics (in-process view).';

  @override
  Future<int> run() => withApp((app) async {
    final channel = App.make<CoordinatorChannel>();
    if (channel is LocalCoordinatorChannel) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(channel.coordinator.stats()),
      );
    } else {
      stdout.writeln(
        'Coordinator is remote; stats are only available in-process.',
      );
    }
    return 0;
  });
}

/// `storage:link [--force]` — creates `public/storage` → `storage/app/public`.
final class StorageLinkCommand extends DaravelCommand {
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
