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
