import 'dart:async';

import '../cache/cache.dart';
import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../foundation/cancellation.dart';
import '../foundation/config.dart';
import '../foundation/container.dart';
import '../foundation/exceptions.dart';
import '../http/rate_limiter.dart';
import 'queue_manager.dart';

/// A unit of background work (BLUEPRINT_V2 §7.9.1). Jobs are plain Dart
/// objects serialised to JSON through [toJson] and rebuilt by the factory
/// registered in [JobRegistry] (no reflection, AOT-friendly).
abstract class Job {
  /// Jobs are usually const or plain data classes.
  const Job();

  /// Stable registry key (survives class renames).
  String get jobName;

  /// JSON payload; models go in as keys (see [ModelRef]).
  Map<String, Object?> toJson();

  /// Does the job's work; throw to fail the attempt.
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

  /// The queue this job goes to; the connection's default when null.
  String? get queue => null;

  /// The connection this job goes to; the default one when null.
  String? get connection => null;

  /// Laravel's `$maxExceptions`: the job fails once it has thrown this many
  /// exceptions, however many [tries] are left (releases do not count).
  /// Null (the default) or 0 leaves only [tries] and [retryUntil].
  int? get maxExceptions => null;

  /// Laravel's `$deleteWhenMissingModels`: a job whose [ModelRef] row is gone
  /// is dropped, not failed.
  bool get deleteWhenMissingModels => false;

  /// Whether a timeout fails the job immediately instead of retrying.
  ///
  /// Under `daravel_horizon`, a job that blocks its isolate past its
  /// timeout (synchronous work the processor cannot interrupt) has its
  /// worker killed by the master, and is tried again until its tries are
  /// used up, whatever this says.
  bool get failOnTimeout => false;

  /// Middleware wrapping [handle]: [WithoutOverlapping], [RateLimitedJob]...
  List<JobMiddleware> get middleware => const <JobMiddleware>[];

  /// Called once the job is marked failed.
  Future<void> failed(Object error, StackTrace stackTrace) async {}

  /// `ShouldBeUnique`: when non-null, a job with the same id cannot be
  /// pushed again until this one finishes (or [uniqueFor] elapses).
  String? get uniqueId => null;

  /// How long a unique job stays unique (`ShouldBeUnique`); zero for no
  /// limit.
  Duration get uniqueFor => Duration.zero;

  /// Laravel 13's `DebounceFor`: when set, a dispatch replaces the pending
  /// one with the same [debounceId], and only the last runs, this long after
  /// it. Cannot be combined with [uniqueId].
  Duration? get debounceFor => null;

  /// Runs at the latest this long after the first of a burst.
  Duration? get debounceMaxWait => null;

  /// The id that groups debounced dispatches; empty for no debounce.
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
  /// A job registered as [name], rebuilt from its JSON by [fromJson].
  const JobDefinition(this.name, this.fromJson);

  /// The name stored in the payload.
  final String name;

  /// Rebuilds the job from the data its `toJson` gave.
  final Job Function(Map<String, Object?> json) fromJson;
}

/// Thrown when a payload names a job that is not registered.
final class UnknownJobException extends DaravelException {
  /// No job is registered as [name] (`bootstrap/jobs.dart`).
  UnknownJobException(String name)
    : super(
        'Job [$name] is not registered. Add a JobDefinition to '
        'bootstrap/jobs.dart (withJobs).',
      );
}

/// Laravel's `MaxAttemptsExceededException`: a job reserved once more after
/// it used up its tries (released by middleware, or abandoned past its
/// timeout) or its `retryUntil`; it fails without running.
final class MaxAttemptsExceededException extends DaravelException {
  /// [displayName] was attempted too many times or too late.
  MaxAttemptsExceededException(String displayName, {required int attempts})
    : super(
        '$displayName has been attempted too many times or run too long '
        '($attempts attempts). The job may have previously timed out.',
      );
}

/// Explicit job registry (ADR-002).
final class JobRegistry {
  /// A registry of [definitions].
  JobRegistry([Iterable<JobDefinition> definitions = const []]) {
    registerAll(definitions);
  }

  final Map<String, JobDefinition> _definitions = <String, JobDefinition>{};

  /// Registers [definition].
  void register(JobDefinition definition) =>
      _definitions[definition.name] = definition;

  /// Registers every one of [definitions].
  void registerAll(Iterable<JobDefinition> definitions) =>
      definitions.forEach(register);

  /// Whether a job is registered as [name].
  bool has(String name) => _definitions.containsKey(name);

  /// The registered job names.
  Iterable<String> get names => _definitions.keys;

  /// Rebuilds the job [name] from [json]; throws [UnknownJobException]
  /// when it is not registered.
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
  /// The context of one attempt of a job.
  JobContext({
    required this.id,
    required this.attempt,
    required this.queue,
    required this.connection,
    required this.payload,
    this.maxTries,
  });

  /// The job's id in its queue.
  final Object id;

  /// 1-based attempt number.
  final int attempt;

  /// The queue it was reserved from.
  final String queue;

  /// The connection it was reserved from.
  final String connection;

  /// Raw JSON payload of the job.
  final Map<String, Object?> payload;

  /// Effective maximum attempts (`null` = unlimited).
  final int? maxTries;

  /// Cancelled when the handler exceeded its timeout. The handler runs with
  /// it as [CancellationToken.current], so a `DB.transaction` it is still
  /// in rolls back instead of committing.
  final CancellationToken cancellation = CancellationToken();

  /// Set when the handler exceeded its timeout; long loops should check it
  /// and return early (Dart cannot kill a running Future). From then on its
  /// transactions roll back instead of committing ([cancellation]).
  bool get cancelled => cancellation.isCancelled;

  /// Setting it to true cancels [cancellation]; it cannot be undone.
  set cancelled(bool value) {
    if (value) {
      cancellation.cancel('Job attempt $attempt of $id was given up');
    }
  }

  Duration? _release;
  bool _delete = false;
  Object? _failure;

  /// Whether the job asked to be released back to the queue.
  bool get released => _release != null;

  /// How long until the released job runs again.
  Duration? get releaseDelay => _release;

  /// Whether the job asked to be deleted without failing.
  bool get deleted => _delete;

  /// The error the job failed with, when it called `fail`.
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
  /// Runs around [job]: call [next] to continue, or return without it.
  Future<void> handle(JobContext ctx, Job job, JobNext next);
}

/// Prevents concurrent runs sharing [key] by holding a cache lock. When the
/// lock is taken the job is released after [releaseAfter] (or deleted when
/// [dontRelease] is true).
final class WithoutOverlapping implements JobMiddleware {
  /// Lets one job with [key] run at a time; the others are released after
  /// [releaseAfter], or dropped when [dontRelease].
  const WithoutOverlapping(
    this.key, {
    this.expiresAfter = const Duration(minutes: 1),
    this.releaseAfter = Duration.zero,
    this.dontRelease = false,
    this.store,
    this.shared = false,
  });

  /// The key that may not overlap.
  final String key;

  /// How long the lock lasts if a job never finishes.
  final Duration expiresAfter;

  /// How long until an overlapping job is tried again.
  final Duration releaseAfter;

  /// Whether an overlapping job is dropped instead of released.
  final bool dontRelease;

  /// Cache store holding the lock (default: `QUEUE_UNIQUE_LOCK_STORE`).
  final String? store;

  /// Laravel's `shared()`: different job classes with this [key] exclude
  /// each other.
  final bool shared;

  @override
  Future<void> handle(JobContext ctx, Job job, JobNext next) async {
    final cache = Container.current.make<CacheManager>().store(
      store ??
          Container.current
              .make<ConfigRepository>()
              .section<QueueConfig>()
              .uniqueLockStore,
    );
    // The previous release's key first, then Laravel's (ADR-041): an
    // instance of either release excludes the other during a deploy.
    final locks = [
      if (QueueLockKeys.legacyKeys)
        cache.lock(
          QueueLockKeys.legacyOverlap(job.jobName, key, shared: shared),
          ttl: expiresAfter,
        ),
      cache.lock(
        QueueLockKeys.overlap(job.displayName, key, shared: shared),
        ttl: expiresAfter,
      ),
    ];
    final held = <Lock>[];
    for (final lock in locks) {
      if (!await lock.acquire()) {
        for (final taken in held.reversed) {
          await taken.release();
        }
        if (dontRelease) {
          ctx.delete();
        } else {
          ctx.release(releaseAfter);
        }
        return;
      }
      held.add(lock);
    }
    try {
      await next();
    } finally {
      // A handler past its timeout still runs: its lock stays until
      // [expiresAfter], as when Laravel kills the worker, so the retry does
      // not run next to it.
      if (!ctx.cancelled) {
        for (final lock in held.reversed) {
          await lock.release();
        }
      }
    }
  }
}

/// Limits how often jobs sharing a key run (uses the application's
/// [RateLimiter] store, so the limit is process-wide under a supervisor).
final class RateLimitedJob implements JobMiddleware {
  /// At most [maxAttempts] jobs with [key] per [decay]; the rest are
  /// released until the window resets.
  const RateLimitedJob(
    this.key, {
    required this.maxAttempts,
    required this.decay,
    this.releaseAfter,
  });

  /// The key counted.
  final String key;

  /// The jobs allowed per window.
  final int maxAttempts;

  /// The length of the window.
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
  /// A reference to the model with [id], serialized as the id and loaded
  /// again when the job runs (Laravel's `SerializesModels`).
  const ModelRef(this.definition, this.id);

  /// Builds a reference from a loaded model.
  factory ModelRef.of(T model) => ModelRef<T>(
    () => model.modelDefinition as ModelDefinition<T>,
    model.key!,
  );

  /// The model's definition.
  final ModelDefinition<T> Function() definition;

  /// The model's primary key.
  final Object id;

  /// The model, loaded fresh; a 404 when it was deleted meanwhile.
  Future<T> resolve() => definition().query().findOrFail(id);

  /// The id, as stored in the payload.
  Object toJson() => id;
}

/// The cache keys of a job's unique lock, `WithoutOverlapping` lock and
/// debounce owner, in Laravel's format (ADR-041), so a Laravel and a
/// Daravel application sharing a cache (same `CACHE_PREFIX`) see each
/// other's locks:
///
/// - unique: `laravel_unique_job:<displayName>:<uniqueId>`
///   (`Illuminate\Bus\UniqueLock::getKey`, 12.x lines 66-77);
/// - overlap: `laravel-queue-overlap:<displayName>:<key>`, or
///   `laravel-queue-overlap:<key>` when shared
///   (`Illuminate\Queue\Middleware\WithoutOverlapping`, 12.x lines 41 and
///   157-168);
/// - debounce: `laravel_debounced_job:<displayName>:<debounceId>`
///   (`Illuminate\Bus\DebounceLock::getKey`, 13.x lines 159-170; 12.x has
///   no debounce).
///
/// `<displayName>` is the job's [Job.displayName], the payload's
/// `displayName`, which is the class name on the Laravel side: Laravel uses
/// the class name, unhashed, for a job without a `displayName()` method,
/// which is the usual case. Its `xxh128(displayName())` branch, for a job
/// class that defines one, is not followed yet.
///
/// Until [legacyKeys] is removed (ADR-041: the minor release after 1.28.0),
/// the keys Daravel used before (`unique:<jobName>:<id>`,
/// `overlap:[<jobName>:]<key>`, `debounced_job:<jobName>:<id>`) are taken
/// and written too, so an instance of the previous release, still running
/// during a rolling deploy, and a new one exclude each other in both
/// directions.
abstract final class QueueLockKeys {
  /// Whether the keys of the previous release are taken and written too
  /// (the transition of ADR-041). Removed in the minor release after
  /// 1.28.0.
  static const bool legacyKeys = true;

  /// The unique lock of [displayName] with [uniqueId].
  static String unique(String displayName, String uniqueId) =>
      'laravel_unique_job:$displayName:$uniqueId';

  /// The unique lock of the previous release.
  static String legacyUnique(String jobName, String uniqueId) =>
      'unique:$jobName:$uniqueId';

  /// The `WithoutOverlapping` lock of [key]: shared across job classes, or
  /// of [displayName] only.
  static String overlap(
    String displayName,
    String key, {
    bool shared = false,
  }) => shared
      ? 'laravel-queue-overlap:$key'
      : 'laravel-queue-overlap:$displayName:$key';

  /// The `WithoutOverlapping` lock of the previous release.
  static String legacyOverlap(
    String jobName,
    String key, {
    bool shared = false,
  }) => shared ? 'overlap:$key' : 'overlap:$jobName:$key';

  /// The debounce owner of [displayName] with [debounceId].
  static String debounce(String displayName, String debounceId) =>
      'laravel_debounced_job:$displayName:$debounceId';

  /// The debounce owner of the previous release.
  static String legacyDebounce(String jobName, String debounceId) =>
      'debounced_job:$jobName:$debounceId';

  /// Both unique-lock keys of a queued job from its payload's
  /// [uniqueKey] (in either format), [displayName] and [jobName]: what a
  /// worker releases, whichever release dispatched it. Just [uniqueKey]
  /// when it is in neither format.
  static List<String> uniqueKeysOf(
    String uniqueKey, {
    required String displayName,
    required String jobName,
  }) {
    final current = 'laravel_unique_job:$displayName:';
    final legacy = 'unique:$jobName:';
    if (uniqueKey.startsWith(current)) {
      final id = uniqueKey.substring(current.length);
      return [uniqueKey, if (legacyKeys) legacyUnique(jobName, id)];
    }
    if (uniqueKey.startsWith(legacy)) {
      final id = uniqueKey.substring(legacy.length);
      return [unique(displayName, id), uniqueKey];
    }
    return [uniqueKey];
  }
}
