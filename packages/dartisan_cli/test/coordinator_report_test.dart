import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
  test('reads what a server under a supervisor reports', () async {
    final coordinator = createStandardCoordinator();
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(() {
      channel.close();
      coordinator.close();
    });
    final metrics = AppMetrics(MetricsRegistry(), channel: channel);
    final store = ProcessStore(channel);
    for (var i = 0; i < 20; i++) {
      await store.increment('hits');
    }
    // What `/metrics` serves: this worker plus the coordinator's counters.
    final text = MetricsRegistry.renderSnapshot({
      ...metrics.registry.snapshot(),
      ...MetricsService.coordinatorSnapshot(coordinator.stats()),
    });
    final report = CoordinatorReport.parse(text);
    expect(report.messages, 20);
    expect(report.rejected, 0);
    expect(report.maxQueue, coordinator.maxQueue);
    final cache = report.calls['processCache']!;
    expect(cache.count, 20);
    expect(cache.quantile(0.5), isNotNull);
    expect(cache.quantile(0.99)!, lessThanOrEqualTo(1));
    expect(report.render(), contains('processCache'));
  });

  test('advice for refused, slow and timed-out calls', () {
    const text = '''
# TYPE coordinator_messages_total counter
coordinator_messages_total 5000
coordinator_rejected_total 12
coordinator_in_flight 0
coordinator_in_flight_peak 10000
coordinator_max_queue 10000
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="0.001"} 50
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="0.005"} 98
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="+Inf"} 100
coordinator_call_duration_seconds_count{service="rateLimiter"} 100
coordinator_call_duration_seconds_sum{service="rateLimiter"} 0.2
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="0.001"} 50
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="0.005"} 100
coordinator_call_duration_seconds_bucket{service="rateLimiter",le="+Inf"} 100
coordinator_call_duration_seconds_count{service="rateLimiter"} 100
coordinator_call_timeouts_total{service="processCache"} 3
''';
    final report = CoordinatorReport.parse(text);
    // Two workers' series are added up.
    final limiter = report.calls['rateLimiter']!;
    expect(limiter.count, 200);
    expect(limiter.quantile(0.5), 0.001);
    expect(limiter.quantile(0.99), 0.005);
    final advice = report.advice();
    expect(advice, hasLength(3));
    expect(advice[0], contains('12 call(s) were refused'));
    expect(advice, contains('processCache: 3 call(s) timed out.'));
    expect(advice, contains(contains('rateLimiter: p99 ≤ 5.0 ms')));
    expect(advice, contains(contains('CACHE_LIMITER=database')));
  });

  test('nothing to do on a quiet server', () {
    final report = CoordinatorReport.parse('coordinator_max_queue 10000\n');
    expect(report.advice(), isEmpty);
    expect(report.render(), contains('No action needed.'));
  });
}
