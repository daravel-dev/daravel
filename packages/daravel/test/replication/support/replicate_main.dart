import 'dart:io';

import 'package:daravel/daravel.dart';

/// Replicates `args[0]` to the local disk at `args[1]` every 20 ms and
/// prints `synced <generation> <frames>` after each sync, until killed
/// (replication_test.dart kills it with SIGKILL).
Future<void> main(List<String> args) async {
  final replicator = SqliteReplicator(
    args[0],
    LocalDisk('replica', args[1]),
    checkpointPages: 30,
  );
  while (true) {
    final sync = await replicator.sync();
    stdout.writeln('synced ${sync.generation} ${sync.frames}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
