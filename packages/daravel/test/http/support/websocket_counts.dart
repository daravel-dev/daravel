import 'dart:async';

import 'package:daravel/src/http/websocket_stats.dart';
import 'package:test/test.dart';

/// That everything the WebSocket connections of this isolate held is
/// released once they ended: messages being assembled, what was held for
/// handlers that do not read, what waited to be written and what waited in
/// the send queues all count zero. A count left over is data left over.
///
/// Registered first in `main` (`tearDown(expectWebSocketCountsReleased)`),
/// it runs after the tests' own tear-downs, the engine's stop included.
Future<void> expectWebSocketCountsReleased() async {
  const names = ['assembling', 'held', 'heldItems', 'waiting', 'queued'];
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var counts = WebSocketGuardStats.toJson();
  while (names.any((name) => counts[name] != 0) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    counts = WebSocketGuardStats.toJson();
  }
  expect(
    {for (final name in names) name: counts[name]},
    {for (final name in names) name: 0},
    reason: 'released once the connections ended',
  );
}
