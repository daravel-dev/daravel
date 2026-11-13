import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'signals.dart';
import 'ui.dart';
import 'store/horizon_store.dart';

/// The dashboard's JSON API (Blueprint #134 §3.7), under `HORIZON_PATH`
/// with Laravel Horizon's route names (`horizon.*`).
///
/// Every request is authorized after the route middleware, as Laravel
/// Horizon's `Authenticate` middleware does: `APP_ENV=local` passes;
/// otherwise the [auth] callback decides, or without one the
/// `viewHorizon` gate; anything else is a 403. Middleware is never taken
/// as authorization. With `HORIZON_ENABLED=false` every endpoint is a
/// 404. Payloads, contexts and traces are returned as
/// JSON strings, for the page to show as text.
abstract final class HorizonDashboard {
  static FutureOr<bool> Function(Request request)? _authUsing;

  /// Who may see the dashboard (Laravel's `Horizon::auth`); null forgets
  /// it.
  static void auth(FutureOr<bool> Function(Request request)? callback) =>
      _authUsing = callback;

  /// Registers the API under [path] behind [middleware].
  static void routes(
    Router router, {
    required String path,
    List<Object> middleware = const [],
  }) {
    Future<Response> guard(FutureOr<Object?> Function(Request r) body) =>
        _guard(body);
    // The prefix of every URL below path: '' at the root, so that
    // nothing (route, link or fetch) starts with //.
    final prefix = path == '/' ? '' : path;
    final api = '$prefix/api';
    router.group((r) {
      r
        ..get(
          '$api/stats',
          (Request q) => guard(_stats),
        ).name('horizon.stats.index')
        ..get(
          '$api/stream',
          (Request q) => guard(_stream),
        ).name('horizon.stream')
        ..get(
          '$api/workload',
          (Request q) => guard(_workload),
        ).name('horizon.workload.index')
        ..get(
          '$api/masters',
          (Request q) => guard(_masters),
        ).name('horizon.masters.index')
        ..get(
          '$api/monitoring',
          (Request q) => guard(_monitored),
        ).name('horizon.monitoring.index')
        ..post(
          '$api/monitoring',
          (Request q) => guard(_monitor),
        ).name('horizon.monitoring.store')
        ..get(
          '$api/monitoring/{tag}',
          (Request q) => guard(_tagged),
        ).name('horizon.monitoring-tag.paginate')
        ..delete(
          '$api/monitoring/{tag}',
          (Request q) => guard(_unmonitor),
        ).name('horizon.monitoring-tag.destroy')
        ..get(
          '$api/metrics/jobs',
          (Request q) => guard(_jobMetrics),
        ).name('horizon.jobs-metrics.index')
        ..get(
          '$api/metrics/jobs/{name}',
          (Request q) => guard(_jobMetric),
        ).name('horizon.jobs-metrics.show')
        ..get(
          '$api/metrics/queues',
          (Request q) => guard(_queueMetrics),
        ).name('horizon.queues-metrics.index')
        ..get(
          '$api/metrics/queues/{queue}',
          (Request q) => guard(_queueMetric),
        ).name('horizon.queues-metrics.show')
        ..get(
          '$api/jobs/pending',
          (Request q) => guard(_pending),
        ).name('horizon.pending-jobs.index')
        ..get(
          '$api/jobs/completed',
          (Request q) => guard((r) => _recent(r, 'completed')),
        ).name('horizon.completed-jobs.index')
        ..get(
          '$api/jobs/silenced',
          (Request q) => guard((r) => _recent(r, 'silenced')),
        ).name('horizon.silenced-jobs.index')
        ..get(
          '$api/jobs/failed',
          (Request q) => guard((r) => _recent(r, 'failed')),
        ).name('horizon.failed-jobs.index')
        ..get(
          '$api/jobs/failed/{uuid}',
          (Request q) => guard(_failedJob),
        ).name('horizon.failed-jobs.show')
        ..post(
          '$api/jobs/retry-all',
          (Request q) => guard(_retryAll),
        ).name('horizon.retry-all')
        ..post(
          '$api/jobs/retry/{uuid}',
          (Request q) => guard(_retry),
        ).name('horizon.retry-jobs.show')
        ..get(
          '$api/jobs/{uuid}',
          (Request q) => guard(_job),
        ).name('horizon.jobs.show')
        ..get(
          path,
          (Request q) => guard((r) => _page(prefix, 'dashboard')),
        ).name('horizon.index')
        ..get(
          '$prefix/{view}',
          (Request q) => guard((r) => _page(prefix, r.param<String>('view'))),
        ).name('horizon.view');
    }, middleware: middleware);
  }

  /// The page, with a fresh CSP nonce for its inline style and script;
  /// an unknown tab is a 404.
  static Response _page(String base, String tab) {
    if (!horizonTabs.contains(tab)) {
      throw NotFoundHttpException();
    }
    final nonce = base64Url
        .encode(List<int>.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    return Response.html(
      horizonPage(base: base, nonce: nonce, tab: tab).render(),
      headers: {
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'x-frame-options': 'DENY',
        'x-robots-tag': 'noindex, nofollow',
        'content-security-policy':
            "default-src 'none'; script-src 'nonce-$nonce'; "
            "style-src 'nonce-$nonce'; connect-src 'self'; img-src data:; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      },
    );
  }

  static HorizonConfig get _config {
    final repository = Container.current.make<ConfigRepository>();
    return repository.hasSection<HorizonConfig>()
        ? repository.section<HorizonConfig>()
        : const HorizonConfig();
  }

  static Future<Response> _guard(
    FutureOr<Object?> Function(Request request) body,
  ) async {
    if (!_config.enabled) {
      throw NotFoundHttpException();
    }
    final request = Container.current.make<Request>();
    if (!await _authorized(request)) {
      throw const ForbiddenHttpException(
        'Horizon is closed outside local: with sessions, sign in as a user '
        'the viewHorizon gate allows; without, HorizonDashboard.auth '
        'decides.',
      );
    }
    final result = await body(request);
    return switch (result) {
      final Response response => response,
      _ => Response.json(result, headers: const {'cache-control': 'no-store'}),
    };
  }

  /// Whether [request] may use the dashboard. A callback or a gate that
  /// throws denies it, logged.
  static Future<bool> _authorized(Request request) async {
    final app = Container.current.make<ConfigRepository>().section<AppConfig>();
    if (app.isLocal) {
      return true;
    }
    try {
      if (_authUsing case final callback?) {
        return await callback(request);
      }
      return Gate.has('viewHorizon') && await Gate.allows('viewHorizon');
    } on Object catch (e, stack) {
      Container.current.make<Logger>().error(
        'Horizon dashboard authorization failed; the request is denied.',
        error: e,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// [read] from the store, or null when it fails.
  static Future<T?> _call<T>(
    String op,
    Future<T> Function(HorizonStore store) read,
  ) async {
    try {
      return await read(horizonStoreOf(Container.current));
    } on CoordinatorException catch (error) {
      // No Horizon store in this process (Horizon runs elsewhere with the
      // process store): empty rather than a 500.
      if (!error.message.startsWith('Unknown coordinator service')) {
        Log.debug('Horizon dashboard: [$op] failed: ${error.message}');
      }
      return null;
    } on Object catch (error) {
      Log.debug('Horizon dashboard: [$op] failed: $error');
      return null;
    }
  }

  static QueueManager get _queues => Container.current.make<QueueManager>();

  static String get _name => _config.name ?? 'horizon';

  /// Horizon's last status; one that cannot be read, or of another shape
  /// (another version wrote it, the store failed), is `inactive`.
  static Future<Map<String, Object?>> _status() async {
    try {
      final status = await HorizonSignals.status(_queues.signalStore, _name);
      return {
        ...status,
        'state': status['state'] is String ? status['state'] : 'inactive',
        'supervisors': _supervisorsOf(status),
      };
    } on Object {
      return {'state': 'inactive', 'supervisors': <String, Object?>{}};
    }
  }

  /// The workers of each supervisor in [status], as a list per name.
  static Map<String, List<Object?>> _supervisorsOf(
    Map<String, Object?> status,
  ) => switch (status['supervisors']) {
    final Map<Object?, Object?> supervisors => {
      for (final MapEntry(:key, :value) in supervisors.entries)
        '$key': value is List ? List<Object?>.of(value) : const <Object?>[],
    },
    _ => const {},
  };

  /// What `stats`, `workload` and `stream` show, worked out at most once a
  /// second per application ([Clock] time), however many clients ask: each
  /// queue's size and rates are read once a tick, not once per client.
  static final Expando<_Snapshot> _snapshots = Expando('horizon snapshot');

  /// The snapshot being worked out, per application: clients that ask
  /// meanwhile (as the last one expires) wait for it rather than each
  /// reading the queues again.
  ///
  /// A [SharedResult]: a failure reaches every waiter, each in its own
  /// zone (a future failing in one request's zone would leave a waiter
  /// from another hanging).
  static final Expando<SharedResult<_Snapshot>> _taking = Expando(
    'horizon snapshot in progress',
  );

  static Future<_Snapshot> _snapshot() async {
    final key = _queues;
    final now = Clock.now();
    final last = _snapshots[key];
    if (last != null && now.difference(last.at) < const Duration(seconds: 1)) {
      return last;
    }
    final taking = _taking[key] ??= SharedResult(() async {
      try {
        final status = await _status();
        final loads = await _queueLoads(status);
        final summary = await _call('summary', (s) => s.summary()) ?? const {};
        return _snapshots[key] = _Snapshot(
          now,
          _statsOf(status, loads, summary),
          loads,
        );
      } finally {
        _taking[key] = null;
      }
    });
    return taking.value;
  }

  /// Each plan queue: its connection, size, workers and estimated wait.
  static Future<List<Map<String, Object?>>> _queueLoads(
    Map<String, Object?> status,
  ) async {
    final supervisors = _supervisorsOf(status);
    final loads = <Map<String, Object?>>[];
    for (final plan in _config.plans) {
      final workers = supervisors[plan.name.value] ?? const <Object?>[];
      final connection = plan.connection ?? _queues.config.defaultConnection;
      for (final queue in plan.queues) {
        int? size;
        try {
          size = await _queues.connection(connection).size(queue.value);
        } on Object {
          size = null;
        }
        final rates = await _call('rates', (s) => s.rates(queue.value));
        final avg = (rates?['avg_ms'] as num?)?.toDouble();
        final processes = workers
            .where((w) => _queuesOf(w).contains(queue.value))
            .length;
        loads.add({
          'name': queue.value,
          'connection': connection,
          'supervisor': plan.name.value,
          'length': size,
          'processes': processes,
          // Laravel's estimate: the backlog times the run time, spread over
          // the workers on the queue.
          'wait': size == null || avg == null
              ? null
              : (size * avg / 1000 / (processes == 0 ? 1 : processes)).round(),
        });
      }
    }
    return loads;
  }

  /// The queues of a worker in a master's status: the comma-separated
  /// list it was assigned ([HorizonMaster.status]), or a list.
  static Iterable<String> _queuesOf(Object? worker) =>
      switch ((worker as Map?)?['queues']) {
        final String queues => queues.split(',').map((q) => q.trim()),
        final List<Object?> queues => queues.whereType<String>(),
        _ => const <String>[],
      };

  static Future<Object?> _stats(Request request) async =>
      (await _snapshot()).stats;

  static Map<String, Object?> _statsOf(
    Map<String, Object?> status,
    List<Map<String, Object?>> loads,
    Map<Object?, Object?> summary,
  ) {
    final supervisors = _supervisorsOf(status);
    return {
      'status': status['state'],
      'jobsPerMinute': summary['jobs_per_minute'] ?? 0,
      'recentJobs': summary['jobs_past_hour'] ?? 0,
      'failedJobs': summary['failed_past_week'] ?? 0,
      'processes': supervisors.values.fold<int>(
        0,
        (sum, workers) => sum + workers.length,
      ),
      'wait': {
        for (final load in loads)
          '${load['connection']}:${load['name']}': load['wait'],
      },
      'periods': {
        'recentJobs': _config.trim.recent.inMinutes,
        'failedJobs': _config.trim.failed.inMinutes,
      },
    };
  }

  static final Random _random = Random.secure();

  /// `stats` and `workload` every second, with a random `retry:` (1 to 5 s)
  /// so clients do not all reconnect at once; it ends when the server
  /// drains.
  static Future<Object?> _stream(Request request) async =>
      Response.sse(() async* {
        yield SseEvent(
          'connected',
          event: 'hello',
          retry: Duration(milliseconds: 1000 + _random.nextInt(4001)),
        );
        while (true) {
          final snapshot = await _snapshot();
          yield SseEvent({
            'stats': snapshot.stats,
            'workload': snapshot.loads,
          }, event: 'update');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }(), heartbeat: null);

  static Future<Object?> _workload(Request request) async =>
      (await _snapshot()).loads;

  static Future<Object?> _masters(Request request) async => {
    _name: await _status(),
  };

  static Future<Object?> _monitored(Request request) async =>
      await _call('monitored', (s) => s.monitored()) ?? const <Object?>[];

  static Future<Object?> _monitor(Request request) async {
    final tag = await request.input<Object?>('tag');
    if (tag is! String || tag.trim().isEmpty) {
      return Response.json({'message': 'A tag is required.'}, status: 422);
    }
    return _change('monitor', (s) => s.monitor(tag.trim()));
  }

  static Future<Object?> _unmonitor(Request request) =>
      _change('unmonitor', (s) => s.unmonitor(request.param<String>('tag')));

  /// [change] on the store: 204, or a 500 when the store fails, logged.
  /// Unlike a read, a change that did not happen is never an empty answer.
  static Future<Response> _change(
    String op,
    Future<void> Function(HorizonStore store) change,
  ) async {
    try {
      await change(horizonStoreOf(Container.current));
      return Response.noContent();
    } on Object catch (error, stackTrace) {
      Container.current.make<Logger>().error(
        'Horizon dashboard: [$op] failed.',
        error: error,
        stackTrace: stackTrace,
      );
      return Response.json({
        'message': 'The Horizon store could not $op the tag.',
      }, status: 500);
    }
  }

  static Future<Object?> _tagged(Request request) async => {
    'jobs':
        (await _call(
          'tagged',
          (s) => s.tagged(request.param<String>('tag'), limit: _limit(request)),
        ))?.map((job) => job.toJson()).toList() ??
        const <Object?>[],
  };

  static Future<Map<String, Object?>> _metrics() async =>
      await _call('metrics', (s) => s.metrics()) ??
      const {'jobs': <String, Object?>{}, 'queues': <String, Object?>{}};

  static Future<Object?> _jobMetrics(Request request) async =>
      ((await _metrics())['jobs']! as Map).keys.toList();

  static Future<Object?> _jobMetric(Request request) async =>
      ((await _metrics())['jobs']! as Map)[request.param<String>('name')] ??
      const <Object?>[];

  static Future<Object?> _queueMetrics(Request request) async =>
      ((await _metrics())['queues']! as Map).keys.toList();

  static Future<Object?> _queueMetric(Request request) async =>
      ((await _metrics())['queues']! as Map)[request.param<String>('queue')] ??
      const <Object?>[];

  static int _limit(Request request) =>
      (int.tryParse(request.query['limit'] ?? '') ?? 50).clamp(1, 500);

  /// `starting_at`: a negative one is the start. The process store skips
  /// that many with `Iterable.skip`, which throws for a negative count, and
  /// the list came back empty (the database store's query already reads
  /// it as 0).
  static int _offset(Request request) {
    final offset = int.tryParse(request.query['starting_at'] ?? '') ?? 0;
    return offset < 0 ? 0 : offset;
  }

  /// The pending jobs of every plan queue, one list in plan and queue
  /// order, paged by `limit` and `starting_at` over the whole list.
  static Future<Object?> _pending(Request request) async {
    final jobs = <Object?>[];
    var skip = _offset(request);
    var need = _limit(request);
    for (final plan in _config.plans) {
      final connection = plan.connection ?? _queues.config.defaultConnection;
      final driver = _queues.connection(connection);
      if (driver is! BrowsableQueueDriver) {
        continue;
      }
      for (final queue in plan.queues) {
        if (need == 0) {
          return {'jobs': jobs};
        }
        final page = await driver.pending(
          queue.value,
          limit: need,
          offset: skip,
        );
        if (page.isEmpty) {
          // The whole queue lies before starting_at: skip past it.
          if (skip > 0) {
            skip -= await _pendingCount(driver, queue.value, skip);
          }
          continue;
        }
        skip = 0;
        need -= page.length;
        for (final job in page) {
          jobs.add({...job.toJson(), 'connection': connection});
        }
      }
    }
    return {'jobs': jobs};
  }

  /// How many jobs [queue] has pending, knowing it has at most [atMost]:
  /// by bisection on one-job pages, so a large `starting_at` never reads
  /// more than one job a query.
  static Future<int> _pendingCount(
    BrowsableQueueDriver driver,
    String queue,
    int atMost,
  ) async {
    // Invariant: index lo - 1 holds a job (or lo is 0); index hi holds
    // none.
    var lo = 0;
    var hi = atMost;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if ((await driver.pending(queue, limit: 1, offset: mid)).isEmpty) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  static Future<Object?> _recent(Request request, String status) async => {
    'jobs':
        (await _call(
          'recent',
          (s) => s.recent(
            status,
            limit: _limit(request),
            offset: _offset(request),
          ),
        ))?.map((job) => job.toJson()).toList() ??
        const <Object?>[],
  };

  static Future<Object?> _failedJob(Request request) async {
    final uuid = request.param<String>('uuid');
    final recorded = (await _call('job', (s) => s.job(uuid)))?.toJson();
    final failed = await _queues.processor.failedJobs.find(uuid);
    if (recorded == null && failed == null) {
      throw NotFoundHttpException();
    }
    return {
      ...?recorded,
      if (failed != null) ...{
        'id': '${failed.id}',
        'connection': failed.connection,
        'queue': failed.queue,
        'payload': failed.payload,
        'exception': failed.exception,
        'failed_at': failed.failedAt.toUtc().toIso8601String(),
      },
    };
  }

  static Future<Object?> _job(Request request) async {
    final recorded = await _call(
      'job',
      (s) => s.job(request.param<String>('uuid')),
    );
    if (recorded == null) {
      throw NotFoundHttpException();
    }
    return recorded.toJson();
  }

  static Future<Object?> _retry(Request request) async {
    final uuid = request.param<String>('uuid');
    final retried = await _queues.retryFailed(uuid);
    if (retried == null) {
      throw NotFoundHttpException();
    }
    return {'retried': retried.uuid};
  }

  /// The most jobs one retry-all request pushes back.
  static const int retryAllLimit = 1000;

  /// How long one retry-all request runs, well inside a request's timeout.
  static const Duration retryAllBudget = Duration(seconds: 10);

  /// Retries failed jobs, at most [retryAllLimit] or [retryAllBudget] per
  /// request; nothing goes on after the answer. `remaining` says how many
  /// are left: the dashboard calls again with the `after` and `up_to` it
  /// got, until none are. A retry-all already running answers 409.
  /// (Laravel Horizon has no retry-all: its dashboard retries one job.)
  static Future<Object?> _retryAll(Request request) async {
    final RetryAllResult result;
    try {
      result = await _queues.retryAllFailed(
        limit: retryAllLimit,
        budget: retryAllBudget,
        after: int.tryParse(request.query['after'] ?? '') ?? 0,
        upTo: int.tryParse(request.query['up_to'] ?? ''),
      );
    } on RetryAllRunningException catch (error) {
      return laravelErrorResponse({'message': error.message}, status: 409);
    }
    return {
      'retried': result.retried.length,
      'skipped': [
        for (final job in result.skipped)
          {'id': job.id, 'uuid': job.uuid, 'reason': job.reason},
      ],
      'skipped_count': result.skippedCount,
      'remaining': result.remaining,
      'after': result.after,
      'up_to': result.upTo,
    };
  }
}

/// One tick of the dashboard's figures ([HorizonDashboard._snapshot]).
final class _Snapshot {
  _Snapshot(this.at, this.stats, this.loads);

  final DateTime at;
  final Map<String, Object?> stats;
  final List<Map<String, Object?>> loads;
}
