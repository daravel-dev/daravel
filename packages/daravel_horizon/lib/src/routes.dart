import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'signals.dart';
import 'ui.dart';
import 'store/process_store.dart';

/// The dashboard's JSON API (Blueprint #134 §3.7), under `HORIZON_PATH`
/// with Laravel Horizon's route names (`horizon.*`).
///
/// Outside `APP_ENV=local` and `testing` every endpoint answers 403 until
/// `withHorizon(middleware:)` protects it, and 404 with
/// `HORIZON_ENABLED=false`. Payloads, contexts and traces are returned as
/// JSON strings, for the page to show as text.
abstract final class HorizonDashboard {
  /// Registers the API under [path] behind [middleware].
  static void routes(
    Router router, {
    required String path,
    List<Object> middleware = const [],
  }) {
    final protected = middleware.isNotEmpty;
    Future<Response> guard(FutureOr<Object?> Function(Request r) body) =>
        _guard(protected, body);
    final api = '$path/api';
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
          (Request q) => guard((r) => _page(path, 'dashboard')),
        ).name('horizon.index')
        ..get(
          '$path/{view}',
          (Request q) => guard((r) => _page(path, r.param<String>('view'))),
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
    bool protected,
    FutureOr<Object?> Function(Request request) body,
  ) async {
    if (!_config.enabled) {
      throw NotFoundHttpException();
    }
    final app = Container.current.make<ConfigRepository>().section<AppConfig>();
    if (!protected && !app.isLocal && !app.isTesting) {
      return Response.json({
        'message':
            'Horizon needs middleware outside local: '
            "withHorizon(middleware: ['auth', 'can:viewHorizon']).",
      }, status: 403);
    }
    final result = await body(Container.current.make<Request>());
    return switch (result) {
      final Response response => response,
      _ => Response.json(result, headers: const {'cache-control': 'no-store'}),
    };
  }

  static Future<Object?> _call(String op, [Map<String, Object?>? args]) async {
    try {
      final answer = await Container.current.make<CoordinatorChannel>().call(
        HorizonService.serviceName,
        op,
        args ?? const {},
      );
      return answer is String ? jsonDecode(answer) : answer;
    } on Object {
      // No Horizon store in this process (Horizon runs elsewhere with the
      // process store): empty rather than a 500.
      return null;
    }
  }

  static QueueManager get _queues => Container.current.make<QueueManager>();

  static String get _name => _config.name ?? 'horizon';

  static Future<Map<String, Object?>> _status() async {
    final state = await HorizonSignals.status(_queues.signalStore, _name);
    return state;
  }

  /// Each plan queue: its connection, size, workers and estimated wait.
  static Future<List<Map<String, Object?>>> _queueLoads() async {
    final status = await _status();
    final supervisors =
        (status['supervisors'] as Map<Object?, Object?>?) ?? const {};
    final loads = <Map<String, Object?>>[];
    for (final plan in _config.plans) {
      final workers = (supervisors[plan.name.value] as List<Object?>?) ?? [];
      final connection = plan.connection ?? _queues.config.defaultConnection;
      for (final queue in plan.queues) {
        int? size;
        try {
          size = await _queues.connection(connection).size(queue.value);
        } on Object {
          size = null;
        }
        final rates = (await _call('rates', {'queue': queue.value})) as Map?;
        final avg = (rates?['avg_ms'] as num?)?.toDouble();
        final processes = workers.where((w) {
          final queues = (w as Map?)?['queues'];
          return queues is List && queues.contains(queue.value);
        }).length;
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

  static Future<Object?> _stats(Request request) async {
    final summary = (await _call('summary')) as Map? ?? const {};
    final status = await _status();
    final loads = await _queueLoads();
    final supervisors =
        (status['supervisors'] as Map<Object?, Object?>?) ?? const {};
    return {
      'status': status['state'] ?? 'inactive',
      'jobsPerMinute': summary['jobs_per_minute'] ?? 0,
      'recentJobs': summary['jobs_past_hour'] ?? 0,
      'failedJobs': summary['failed_past_week'] ?? 0,
      'processes': supervisors.values.fold<int>(
        0,
        (sum, workers) => sum + ((workers as List?)?.length ?? 0),
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
          yield SseEvent({
            'stats': await _stats(request),
            'workload': await _queueLoads(),
          }, event: 'update');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }(), heartbeat: null);

  static Future<Object?> _workload(Request request) => _queueLoads();

  static Future<Object?> _masters(Request request) async => {
    _name: await _status(),
  };

  static Future<Object?> _monitored(Request request) async =>
      await _call('monitored') ?? const <Object?>[];

  static Future<Object?> _monitor(Request request) async {
    final tag = await request.input<Object?>('tag');
    if (tag is! String || tag.trim().isEmpty) {
      return Response.json({'message': 'A tag is required.'}, status: 422);
    }
    await _call('monitor', {'tag': tag.trim()});
    return Response.noContent();
  }

  static Future<Object?> _unmonitor(Request request) async {
    await _call('unmonitor', {'tag': request.param<String>('tag')});
    return Response.noContent();
  }

  static Future<Object?> _tagged(Request request) async => {
    'jobs':
        await _call('tagged', {
          'tag': request.param<String>('tag'),
          'limit': _limit(request),
        }) ??
        const <Object?>[],
  };

  static Future<Map<String, Object?>> _metrics() async =>
      ((await _call('metrics')) as Map<String, Object?>?) ??
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

  static Future<Object?> _pending(Request request) async {
    final jobs = <Object?>[];
    for (final plan in _config.plans) {
      final connection = plan.connection ?? _queues.config.defaultConnection;
      final driver = _queues.connection(connection);
      if (driver is! BrowsableQueueDriver) {
        continue;
      }
      for (final queue in plan.queues) {
        for (final job in await driver.pending(
          queue.value,
          limit: _limit(request),
        )) {
          jobs.add({...job.toJson(), 'connection': connection});
        }
      }
    }
    return {'jobs': jobs};
  }

  static Future<Object?> _recent(Request request, String status) async => {
    'jobs':
        await _call('recent', {
          'status': status,
          'limit': _limit(request),
          'offset': int.tryParse(request.query['starting_at'] ?? '') ?? 0,
        }) ??
        const <Object?>[],
  };

  static Future<Object?> _failedJob(Request request) async {
    final uuid = request.param<String>('uuid');
    final recorded = await _call('job', {'uuid': uuid});
    final failed = await _queues.processor.failedJobs.find(uuid);
    if (recorded == null && failed == null) {
      throw NotFoundHttpException();
    }
    return {
      ...?(recorded as Map<String, Object?>?),
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
    final recorded = await _call('job', {
      'uuid': request.param<String>('uuid'),
    });
    if (recorded == null) {
      throw NotFoundHttpException();
    }
    return recorded;
  }

  static Future<Object?> _retry(Request request) async {
    final uuid = request.param<String>('uuid');
    final retried = await _queues.retryFailed(uuid);
    if (retried == null) {
      throw NotFoundHttpException();
    }
    return {'retried': retried.uuid};
  }

  static Future<Object?> _retryAll(Request request) async => {
    'retried': [for (final job in await _queues.retryAllFailed()) job.uuid],
  };
}
