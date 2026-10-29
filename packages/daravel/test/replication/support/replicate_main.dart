import 'dart:io';

import 'package:daravel/daravel.dart';

/// Replicates `args[0]` to the local disk at `args[1]` every 20 ms and
/// prints `synced <start, µs since epoch>` after each sync, until killed
/// (replication_test.dart kills it with SIGKILL).
Future<void> main(List<String> args) async {
  final replicator = SqliteReplicator(
    args[0],
    LocalDisk('replica', args[1]),
    checkpointPages: 30,
  );
  while (true) {
    final started = DateTime.now().microsecondsSinceEpoch;
    await replicator.sync();
    stdout.writeln('synced $started');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
