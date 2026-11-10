import 'dart:async';

import 'package:daravel/daravel.dart';

import 'master.dart';

/// A queue's oldest job has waited longer than its threshold (`waits` of
/// `withHorizon`, `HORIZON_WAITS`), as Laravel Horizon's `LongWaitDetected`:
/// listen for it to send a notification. Dispatched at most once per queue
/// every [HorizonMaster.longWaitEvery].
final class LongWaitDetected {
  /// The [queue] of [connection] has waited [wait], past [threshold].
  const LongWaitDetected({
    required this.connection,
    required this.queue,
    required this.wait,
    required this.threshold,
  });

  /// The queue connection.
  final String connection;

  /// The queue.
  final String queue;

  /// How long its oldest job has waited.
  final Duration wait;

  /// The threshold it passed.
  final Duration threshold;
}

/// The [HorizonEventSink] of [app]: `LongWaitDetected` is dispatched
/// through the application's events; the rest is logged at debug.
HorizonEventSink horizonEvents(Application app) => (event, data) {
  if (event == 'LongWaitDetected') {
    final dispatched = app.run(
      () => app.container.make<EventDispatcher>().dispatch(
        LongWaitDetected(
          connection: '${data['connection']}',
          queue: '${data['queue']}',
          wait: Duration(seconds: data['seconds']! as int),
          threshold: Duration(seconds: data['threshold']! as int),
        ),
      ),
    );
    unawaited(
      dispatched.catchError(
        (Object error) => app.logger.error('LongWaitDetected listener: $error'),
      ),
    );
    return;
  }
  app.logger.debug('Horizon $event $data');
};
