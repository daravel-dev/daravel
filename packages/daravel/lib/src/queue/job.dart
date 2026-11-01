import 'dart:async';

import '../cache/cache.dart';
import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/exceptions.dart';
import '../http/rate_limiter.dart';
import 'queue_manager.dart';

/// A unit of background work (BLUEPRINT_V2 §7.9.1). Jobs are plain Dart
/// objects serialised to JSON through [toJson] and rebuilt by the factory
/// registered in [JobRegistry] (no reflection, AOT-friendly).
abstract class Job {
  const Job();

  /// Stable registry key (survives class renames).
  String get jobName;

  /// JSON payload; models go in as keys (see [ModelRef]).
  Map<String, Object?> toJson();

  Future<void> handle(JobContext ctx);

  /// Attempts before the job is marked failed (`0` = unlimited until
  /// [retryUntil]).
  int get tries => 1;

  /// Handler timeout; afterwards [JobContext.cancelled] is set and the
  /// attempt counts as failed.
  Duration get timeout => const Duration(minutes: 1);

  /// Delay before each retry (last entry repeats).
  List<Duration> get backoff => const <Duration>[];

  /// Retry window measured from the first push (overrides [tries]).
  Duration? get retryUntil => null;

  String? get queue => null;

  String? get connection => null;

  int get maxExceptions => tries;

  /// Laravel's `$deleteWhenMissingModels`: a job whose [ModelRef] row is gone
  /// is dropped, not failed.
  bool get deleteWhenMissingModels => false;

  /// Whether a timeout fails the job immediately instead of retrying.
  bool get failOnTimeout => false;

  List<JobMiddleware> get middleware => const <JobMiddleware>[];

  /// Called once the job is marked failed.
  Future<void> failed(Object error, StackTrace stackTrace) async {}

  /// `ShouldBeUnique`: when non-null, a job with the same id cannot be
  /// pushed again until this one finishes (or [uniqueFor] elapses).
  String? get uniqueId => null;

  Duration get uniqueFor => Duration.zero;

  /// Laravel 13's `DebounceFor`: when set, a dispatch replaces the pending
  /// one with the same [debounceId], and only the last runs, this long after
  /// it. Cannot be combined with [uniqueId].
  Duration? get debounceFor => null;

  /// Runs at the latest this long after the first of a burst.
  Duration? get debounceMaxWait => null;

  String get debounceId => '';

  /// Human readable name (`displayName` in the payload).
  String get displayName => runtimeType.toString();

  /// Tags for monitoring and filtering (`tags()` in Laravel Horizon), such
  /// as `['user:42', 'billing']`. Stored in the payload's `tags` key.
  List<String> get tags => const <String>[];
}

/// Laravel's `ShouldQueue` for mailables and notifications: sending one
/// puts it on the queue instead. Override the getters to pick where.
///
/// ```dart
/// final class InvoicePaid extends Notification with ShouldQueue { ... }
/// ```
abstract mixin class ShouldQueue {
  /// The queue; the default queue when null.
  String? get queue => null;

  /// The connection; the default connection when null.
  String? get connection => null;

  /// How long to wait before it is processed.
  Duration? get delay => null;
}

/// Registry entry: name → factory from JSON.
final class JobDefinition {
  const JobDefinition(this.name, this.fromJson);

  final String name;
  final Job Function(Map<String, Object?> json) fromJson;
}

/// Thrown when a payload names a job that is not registered.
final class UnknownJobException extends DaravelException {
  UnknownJobException(String name)
    : super(
        'Job [$name] is not registered. Add a JobDefinition to '
        'bootstrap/jobs.dart (withJobs).',
      );
}

/// Explicit job registry (ADR-002).
final class JobRegistry {
  JobRegistry([Iterable<JobDefinition> definitions = const []]) {
    registerAll(definitions);
  }

  final Map<String, JobDefinition> _definitions = <String, JobDefinition>{};

  void register(JobDefinition definition) =>
      _definitions[definition.name] = definition;

  void registerAll(Iterable<JobDefinition> definitions) =>
      definitions.forEach(register);

  bool has(String name) => _definitions.containsKey(name);

  Iterable<String> get names => _definitions.keys;

  Job make(String name, Map<String, Object?> json) {
    final definition = _definitions[name];
    if (definition == null) {
      throw UnknownJobException(name);
    }
    return definition.fromJson(json);
  }
}

/// Runtime information and control for a running job.
final class JobContext {
  JobContext({
    required this.id,
    required this.attempt,
    required this.queue,
    required this.connection,
    required this.payload,
    this.maxTries,
  });

  final Object id;

  /// 1-based attempt number.
  final int attempt;
  final String queue;
  final String connection;

  /// Raw JSON payload of the job.
  final Map<String, Object?> payload;

  /// Effective maximum attempts (`null` = unlimited).
  final int? maxTries;

  /// Set when the handler exceeded its timeout; long loops should check it
  /// and return early (Dart cannot kill a running Future).
  bool cancelled = false;

  Duration? _release;
  bool _delete = false;
  Object? _failure;

  bool get released => _release != null;

  Duration? get releaseDelay => _release;

  bool get deleted => _delete;

  Object? get failure => _failure;

  /// Puts the job back on the queue after [delay] (counts as an attempt).
  void release([Duration delay = Duration.zero]) => _release = delay;

  /// Removes the job without marking it failed.
  void delete() => _delete = true;

  /// Marks the job failed immediately with [error].
  void fail([Object? error]) =>
      _failure = error ?? StateError('Job failed via JobContext.fail().');
}

/// Continues the job middleware chain.
typedef JobNext = Future<void> Function();

/// Wraps job execution (Laravel job middleware).
abstract interface class JobMiddleware {
  Future<void> handle(JobContext ctx, Job job, JobNext next);
}

/// Prevents concurrent runs sharing [key] by holding a cache lock. When the
/// lock is taken the job is released after [releaseAfter] (or deleted when
/// [dontRelease] is true).
final class WithoutOverlapping implements JobMiddleware {
  const WithoutOverlapping(
    this.key, {
    this.expiresAfter = const Duration(minutes: 1),
    this.releaseAfter = Duration.zero,
    this.dontRelease = false,
    this.store,
    this.shared = false,
  });

  final String key;
  final Duration expiresAfter;
  final Duration releaseAfter;
  final bool dontRelease;

  /// Cache store holding the lock (default: `QUEUE_UNIQUE_LOCK_STORE`).
  final String? store;

  /// Laravel's `shared()`: different job classes with this [key] exclude
  /// each other.
  final bool shared;

  @override
  Future<void> handle(JobContext ctx, Job job, JobNext next) async {
    final lock = Container.current
        .make<CacheManager>()
        .store(
          store ??
              Container.current
                  .make<ConfigRepository>()
                  .section<QueueConfig>()
                  .uniqueLockStore,
        )
        .lock(
          shared ? 'overlap:$key' : 'overlap:${job.jobName}:$key',
          ttl: expiresAfter,
        );
    if (!await lock.acquire()) {
      if (dontRelease) {
        ctx.delete();
      } else {
        ctx.release(releaseAfter);
      }
      return;
    }
    try {
      await next();
    } finally {
      await lock.release();
    }
  }
}

/// Limits how often jobs sharing a key run (uses the application's
/// [RateLimiter] store, so the limit is process-wide under a supervisor).
final class RateLimitedJob implements JobMiddleware {
  const RateLimitedJob(
    this.key, {
    required this.maxAttempts,
    required this.decay,
    this.releaseAfter,
  });

  final String key;
  final int maxAttempts;
  final Duration decay;

  /// Delay before retrying when limited (default: until the window resets).
  final Duration? releaseAfter;

  @override
  Future<void> handle(JobContext ctx, Job job, JobNext next) async {
    final limiter = Container.current.make<RateLimiter>();
    final result = await limiter.attempt('job:$key', maxAttempts, decay);
    if (!result.allowed) {
      ctx.release(releaseAfter ?? result.retryAfter ?? decay);
      return;
    }
    await next();
  }
}

/// Reference to a model stored in a payload by key (`SerializesModels`).
/// The model is reloaded fresh when the job runs; a missing row throws
/// [ModelNotFoundException], failing the job without retry.
final class ModelRef<T extends Model> {
  const ModelRef(this.definition, this.id);

  /// Builds a reference from a loaded model.
  factory ModelRef.of(T model) => ModelRef<T>(
    () => model.modelDefinition as ModelDefinition<T>,
    model.key!,
  );

  final ModelDefinition<T> Function() definition;
  final Object id;

  Future<T> resolve() => definition().query().findOrFail(id);

  Object toJson() => id;
}
