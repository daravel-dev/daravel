import 'package:daravel/daravel.dart';

/// The `PULSE_*` settings (the names Laravel Pulse uses where it has one).
final class PulseConfig implements ConfigSection {
  const PulseConfig({
    this.enabled = true,
    this.path = '/pulse',
    this.slowRequestThreshold = const Duration(seconds: 1),
    this.slowQueryThreshold = const Duration(seconds: 1),
    this.slowJobThreshold = const Duration(seconds: 1),
    this.queues = const ['default'],
    this.publishEvery = const Duration(seconds: 5),
  });

  factory PulseConfig.fromEnv(Env env) => PulseConfig(
    enabled: env.boolean('PULSE_ENABLED', true),
    path: env.string('PULSE_PATH', '/pulse'),
    slowRequestThreshold: Duration(
      milliseconds: env.integer('PULSE_SLOW_REQUESTS_THRESHOLD', 1000),
    ),
    slowQueryThreshold: Duration(
      milliseconds: env.integer('PULSE_SLOW_QUERIES_THRESHOLD', 1000),
    ),
    slowJobThreshold: Duration(
      milliseconds: env.integer('PULSE_SLOW_JOBS_THRESHOLD', 1000),
    ),
    queues: env.list('PULSE_QUEUES', const ['default']),
    publishEvery: Duration(
      seconds: env.integer('PULSE_PUBLISH_SECONDS', 5).clamp(1, 60),
    ),
  );

  /// `false` records nothing and answers 404 on every route
  /// (`PULSE_ENABLED`).
  final bool enabled;

  /// The dashboard's URL path (`PULSE_PATH`), unless `withPulse` is given
  /// one.
  final String path;

  /// Requests at least this slow are listed (`PULSE_SLOW_REQUESTS_THRESHOLD`,
  /// milliseconds).
  final Duration slowRequestThreshold;

  /// Queries at least this slow are listed (`PULSE_SLOW_QUERIES_THRESHOLD`).
  final Duration slowQueryThreshold;

  /// Jobs at least this slow are listed (`PULSE_SLOW_JOBS_THRESHOLD`).
  final Duration slowJobThreshold;

  /// The queues of the default connection whose size is shown
  /// (`PULSE_QUEUES`, comma separated).
  final List<String> queues;

  /// How often a worker isolate sends what it recorded to the coordinator,
  /// under a supervisor (`PULSE_PUBLISH_SECONDS`).
  final Duration publishEvery;

  @override
  String get key => 'pulse';

  @override
  Map<String, Object?> toMap() => {
    'enabled': enabled,
    'path': path,
    'slow_requests_threshold_ms': slowRequestThreshold.inMilliseconds,
    'slow_queries_threshold_ms': slowQueryThreshold.inMilliseconds,
    'slow_jobs_threshold_ms': slowJobThreshold.inMilliseconds,
    'queues': queues,
    'publish_seconds': publishEvery.inSeconds,
  };
}
