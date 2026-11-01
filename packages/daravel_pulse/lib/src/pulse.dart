import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'recorder.dart';
import 'ui.dart';

/// `withPulse()` on the application builder.
extension PulseApplicationBuilder on ApplicationBuilder {
  /// Records requests, slow queries, exceptions and jobs, and serves the
  /// dashboard at [path] (`PULSE_PATH`, `/pulse`) behind [middleware].
  /// Outside `APP_ENV=local` and `testing` it answers 403 until
  /// [middleware] protects it (`['auth', 'can:viewPulse']`).
  ApplicationBuilder withPulse({
    String? path,
    List<Object> middleware = const [],
  }) =>
      withConfig<PulseConfig>(PulseConfig.fromEnv)
          .withProviders([_PulseProvider(path, middleware)]);
}

final class _PulseProvider extends ServiceProvider {
  _PulseProvider(this.path, this.middleware);
  final String? path;
  final List<Object> middleware;

  @override
  void boot(Container container) {
    final config = container.make<ConfigRepository>().section<PulseConfig>();
    final base = _trim(path ?? config.path);
    final recorder = PulseRecorder();
    container.instance<PulseRecorder>(recorder);
    if (config.enabled) {
      Pulse._record(container, recorder, config, base);
    }
    Pulse.routes(container.make<Router>(), path: base, middleware: middleware);
  }

  static String _trim(String path) => path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
}

/// The dashboard's routes and the hooks that feed it.
abstract final class Pulse {
  /// The topic of the isolates' reports on the coordinator.
  static const String topic = 'pulse';

  static void _record(
    Container container,
    PulseRecorder recorder,
    PulseConfig config,
    String base,
  ) {
    container.make<MiddlewareRegistry>().prepend(
      PulseMiddleware(recorder, config, except: base),
    );
    container.make<ExceptionHandler>().report<Object>((error, stack, _) {
      final client =
          (error is HttpException && error.status < 500) ||
          error is ValidationException;
      if (!client) {
        recorder.recordException(error, stack);
      }
    });
    container.make<DatabaseManager>().listen((QueryExecuted query) {
      if (query.time >= config.slowQueryThreshold) {
        recorder.recordQuery(query.sql, query.connectionName, query.time);
      }
      if (query.poolWait >= config.poolWaitThreshold) {
        recorder.recordPoolWait(query.connectionName, query.poolWait);
      }
      QueryTally.current?.add(query.sql, query.time);
    });
    container.make<DatabaseManager>().listenTransactions((event) {
      if (event is DbTransactionBeginning &&
          event.depth == 1 &&
          event.poolWait >= config.poolWaitThreshold) {
        recorder.recordPoolWait(event.connectionName, event.poolWait);
      }
    });
    container.make<EventDispatcher>()
      ..listen<JobProcessed>((JobProcessed job) {
        if (job.duration >= config.slowJobThreshold) {
          recorder.recordJob(job.jobName, job.queue, job.duration);
        }
      })
      ..listen<ShadowParityDrift>(recorder.recordParityDrift)
      ..listen<JobFailed>(
        (JobFailed job) => recorder.recordJob(
          job.jobName,
          job.queue,
          Duration.zero,
          failed: true,
        ),
      );
    final channel = container.make<CoordinatorChannel>();
    if (channel.isRemote) {
      // Under a supervisor each worker sends its report a few seconds
      // after recording something; one timer at a time, none when idle.
      final reports = WorkerReports(channel, worker: recorder.worker);
      Timer? pending;
      recorder.onRecord = () {
        pending ??= Timer(config.publishEvery, () {
          pending = null;
          reports.publish(topic, recorder.report()).ignore();
        });
      };
    }
  }

  /// Registers the page and its API under [path].
  static void routes(
    Router router, {
    String path = '/pulse',
    List<Object> middleware = const [],
  }) {
    final protected = middleware.isNotEmpty;
    router.group((r) {
      r
          .get(path, (Request request) => _guard(protected, () => _page(path)))
          .name('pulse');
      r.get(
        '$path/api/stats',
        (Request request) => _guard(protected, () => _stats(request)),
      );
    }, middleware: middleware);
  }

  static PulseConfig get _config {
    final repository = Container.current.make<ConfigRepository>();
    return repository.hasSection<PulseConfig>()
        ? repository.section<PulseConfig>()
        : const PulseConfig();
  }

  static Future<Response> _guard(
    bool protected,
    FutureOr<Response> Function() handler,
  ) async {
    if (!_config.enabled) {
      throw NotFoundHttpException();
    }
    final app = Container.current.make<ConfigRepository>().section<AppConfig>();
    if (!protected && !app.isLocal && !app.isTesting) {
      return Response.json({
        'message':
            'Pulse needs middleware outside local: '
            "withPulse(middleware: ['auth', 'can:viewPulse']).",
      }, status: 403);
    }
    return handler();
  }

  static final math.Random _random = math.Random.secure();

  static Response _page(String base) {
    final nonce = base64Url
        .encode(List<int>.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    return Response.html(
      pulsePage(base: base, nonce: nonce),
      headers: {
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'x-frame-options': 'DENY',
        'content-security-policy':
            "default-src 'none'; script-src 'nonce-$nonce'; "
            "style-src 'nonce-$nonce'; connect-src 'self'; img-src data:; "
            "frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      },
    );
  }

  static Future<Response> _stats(Request request) async {
    final container = Container.current;
    final window =
        PulseSnapshot.windows[request.query['period']] ??
        PulseSnapshot.windows['1h']!;
    final now = Clock.now();
    final snapshot = PulseSnapshot.build(
      await reports(container),
      window: window,
      now: now,
    );
    snapshot['queues'] = await _queues(container);
    snapshot['failed_jobs'] = await _failedJobs(container, now, window);
    snapshot['thresholds'] = {
      'requests_ms': _config.slowRequestThreshold.inMilliseconds,
      'queries_ms': _config.slowQueryThreshold.inMilliseconds,
      'jobs_ms': _config.slowJobThreshold.inMilliseconds,
      'pool_ms': _config.poolWaitThreshold.inMilliseconds,
    };
    return Response.json(snapshot, headers: {'cache-control': 'no-store'});
  }

  /// The reports of every isolate: this one's, fresh, and under a
  /// supervisor the latest the others sent to the coordinator.
  static Future<List<Map<String, Object?>>> reports(Container container) async {
    final recorder = container.make<PulseRecorder>();
    final own = recorder.report();
    final channel = container.make<CoordinatorChannel>();
    if (!channel.isRemote) {
      return [own];
    }
    final reports = WorkerReports(channel, worker: recorder.worker);
    await reports.publish(topic, own);
    final all = await reports.collect(topic);
    return [for (final report in all.values) report! as Map<String, Object?>];
  }

  static Future<List<Map<String, Object?>>> _queues(Container container) async {
    final queue = container.make<QueueManager>();
    final connection = queue.config.defaultConnection;
    return [
      for (final name in _config.queues)
        {
          'connection': connection,
          'queue': name,
          'size': await _size(queue, connection, name),
        },
    ];
  }

  static Future<int?> _size(
    QueueManager queue,
    String connection,
    String name,
  ) async {
    try {
      return await queue.connection(connection).size(name);
    } on Object {
      // A missing jobs table or an unreachable Redis: shown as unknown.
      return null;
    }
  }

  /// `failed_jobs` rows of the window, newest first: they come from every
  /// worker process, not only from this server's isolates.
  static Future<Map<String, Object?>> _failedJobs(
    Container container,
    DateTime now,
    Duration window,
  ) async {
    try {
      final from = now.subtract(window);
      final failed = [
        for (final job
            in await container.make<QueueManager>().processor.failedJobs.all())
          if (job.failedAt.isAfter(from)) job,
      ]..sort((a, b) => b.failedAt.compareTo(a.failedAt));
      return {
        'count': failed.length,
        'recent': [
          for (final job in failed.take(5))
            {
              'job': _jobName(job.payload),
              'queue': job.queue,
              'failed_at': job.failedAt.millisecondsSinceEpoch,
              'exception': job.exception.split('\n').first,
            },
        ],
      };
    } on Object {
      return {'count': null, 'recent': const <Object?>[]};
    }
  }

  static String _jobName(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) {
        return '${decoded['displayName'] ?? decoded['job'] ?? '?'}';
      }
    } on FormatException {
      // Not JSON: fall through.
    }
    return '?';
  }
}

/// Times every request except the dashboard's own, and lists the slow
/// ones under their route pattern (`/users/{id}`, never the raw path).
/// The queries of one request, by statement. The bindings are already out
/// of the SQL, so `WHERE id = $1` is the same statement for every id; a list
/// of placeholders collapses, or each length of an `IN` would count apart.
final class QueryTally {
  static final Object _key = Object();
  static final RegExp _placeholder = RegExp(r'\$\d+');
  static final RegExp _list = RegExp(r'\(\s*\?(\s*,\s*\?)+\s*\)');
  static final RegExp _space = RegExp(r'\s+');

  /// The tally of the running request, if Pulse watches it.
  static QueryTally? get current => Zone.current[_key] as QueryTally?;

  final Map<String, int> _counts = {};
  int total = 0;
  Duration time = Duration.zero;

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: this});

  void add(String sql, Duration duration) {
    total++;
    time += duration;
    _counts.update(fingerprint(sql), (n) => n + 1, ifAbsent: () => 1);
  }

  /// The statement run most often, and how often.
  (String, int)? get worst {
    (String, int)? top;
    for (final MapEntry(:key, :value) in _counts.entries) {
      if (top == null || value > top.$2) {
        top = (key, value);
      }
    }
    return top;
  }

  static String fingerprint(String sql) => sql
      .replaceAll(_placeholder, '?')
      .replaceAll(_list, '(?)')
      .replaceAll(_space, ' ')
      .trim();
}

final class PulseMiddleware implements Middleware {
  const PulseMiddleware(this.recorder, this.config, {required this.except});

  final PulseRecorder recorder;
  final PulseConfig config;

  /// The dashboard's path: its polling is not counted.
  final String except;

  @override
  Future<Response> handle(Request request, Next next) async {
    final path = request.path;
    if (path == except || path.startsWith('$except/')) {
      return next(request);
    }
    final stopwatch = Stopwatch()..start();
    recorder.requestStarted();
    var status = 500;
    final tally = QueryTally();
    try {
      final response = await tally.run(() => next(request));
      status = response.status;
      return response;
    } finally {
      final elapsed = stopwatch.elapsed;
      final worst = tally.worst;
      if (worst != null &&
          (worst.$2 >= config.nPlusOneThreshold ||
              tally.total >= config.queryStormThreshold)) {
        recorder.recordStorm(
          method: request.method,
          route: request.route?.path ?? 'unmatched',
          statement: worst.$1,
          count: worst.$2,
          total: tally.total,
          duration: tally.time,
        );
      }
      recorder.recordRequest(
        method: request.method,
        route: request.route?.path ?? 'unmatched',
        status: status,
        duration: elapsed,
        slow: elapsed >= config.slowRequestThreshold,
      );
    }
  }
}
