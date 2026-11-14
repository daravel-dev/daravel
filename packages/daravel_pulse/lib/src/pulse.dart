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
  /// dashboard at [path] (`PULSE_PATH`, `/pulse`).
  ///
  /// Who may open it is decided as Laravel Pulse does: `APP_ENV=local`
  /// passes; otherwise [Pulse.auth] when set, else the `viewPulse` gate;
  /// anything else is a 403 (`APP_ENV=testing` too). [middleware] only
  /// runs before that decision: without it, the `web` group when the
  /// application registers it (the session and its user), else none.
  /// Middleware the application does not register is a ConfigException.
  ApplicationBuilder withPulse({String? path, List<Object>? middleware}) =>
      withConfig<PulseConfig>(PulseConfig.fromEnv)
          .withProviders([_PulseProvider(path, middleware)]);
}

final class _PulseProvider extends ServiceProvider {
  _PulseProvider(this.path, this.given);
  final String? path;
  final List<Object>? given;

  @override
  void boot(Container container) {
    final config = container.make<ConfigRepository>().section<PulseConfig>();
    final base = _trim(path ?? config.path);
    final recorder = PulseRecorder();
    container.instance<PulseRecorder>(recorder);
    if (config.enabled) {
      Pulse._record(container, recorder, config, base);
    }
    final middleware = DashboardGate.middleware(
      container.make<MiddlewareRegistry>(),
      given,
      setup: 'withPulse',
      authHint: 'Pulse.auth',
    );
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

  static FutureOr<bool> Function(Request request)? _authUsing;

  /// Who may see the dashboard outside `APP_ENV=local`, before the
  /// `viewPulse` gate; null forgets it. A Daravel addition (Laravel Pulse
  /// has only the gate), for applications without sessions. Kept per
  /// isolate: call it inside `createApp`, so that every worker isolate has
  /// it; an isolate without it asks the gate.
  static void auth(FutureOr<bool> Function(Request request)? callback) =>
      _authUsing = callback;

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

  /// Registers the page and its API under [path], each request authorized
  /// after [middleware] (see `withPulse`).
  static void routes(
    Router router, {
    String path = '/pulse',
    List<Object> middleware = const [],
  }) {
    router.group((r) {
      r
          .get(path, (Request request) => _guard(request, () => _page(path)))
          .name('pulse');
      r.get(
        '$path/api/stats',
        (Request request) => _guard(request, () => _stats(request)),
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
    Request request,
    FutureOr<Response> Function() handler,
  ) async {
    if (!_config.enabled) {
      throw NotFoundHttpException();
    }
    if (!await DashboardGate.allows(
      request,
      ability: 'viewPulse',
      name: 'Pulse dashboard',
      callback: _authUsing,
    )) {
      throw const ForbiddenHttpException(
        'Pulse is closed outside local: with sessions, sign in as a user '
        'the viewPulse gate allows; without, Pulse.auth decides.',
      );
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
    // daravel_horizon's dashboard, when the application has one: the
    // Queues card links to it (no dependency on the package).
    snapshot['horizon_path'] = horizonPath(container.make<Router>());
    snapshot['failed_jobs'] = await _failedJobs(container, now, window);
    snapshot['reverb'] = await reverb(container);
    // daravel_reverb's dashboard, when the application has one: the Reverb
    // card links to it (no dependency on the package).
    snapshot['reverb_path'] = reverbPath(container.make<Router>());
    snapshot['thresholds'] = {
      'requests_ms': _config.slowRequestThreshold.inMilliseconds,
      'queries_ms': _config.slowQueryThreshold.inMilliseconds,
      'jobs_ms': _config.slowJobThreshold.inMilliseconds,
      'pool_ms': _config.poolWaitThreshold.inMilliseconds,
      'parity_drifts': _config.parityDriftThreshold,
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

  /// The path of `daravel_horizon`'s dashboard (its `horizon.index` route),
  /// or null when the application has none.
  static String? horizonPath(Router router) {
    for (final route in router.routes) {
      if (route.routeName == 'horizon.index') {
        return route.path;
      }
    }
    return null;
  }

  /// The path of `daravel_reverb`'s dashboard (its `reverb.index` route),
  /// or null when the application has none.
  static String? reverbPath(Router router) {
    for (final route in router.routes) {
      if (route.routeName == 'reverb.index') {
        return route.path;
      }
    }
    return null;
  }

  /// The *Reverb* card: each isolate's last report of its Pusher activity
  /// (`ReverbStats`, every `REVERB_PULSE_INGEST_INTERVAL` while it has
  /// connections), one row per isolate and application. Empty, and the
  /// card hidden, when no isolate serves Pusher clients.
  static Future<List<Map<String, Object?>>> reverb(Container container) async {
    final Map<String, Object?> all;
    try {
      all = await ReverbStats.collect(container.make<CoordinatorChannel>());
    } on Object {
      return const [];
    }
    return [
      for (final MapEntry(key: worker, value: report) in all.entries)
        if (report case {'apps': final Map<Object?, Object?> apps})
          for (final MapEntry(key: app, value: stats) in apps.entries)
            if (stats case final Map<Object?, Object?> stats)
              {
                'worker': worker,
                'app': '$app',
                for (final MapEntry(:key, :value) in stats.entries)
                  '$key': value,
                'reported_at': report['at'],
              },
    ];
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

  /// The queries of the current request.
  int total = 0;

  /// The time they took.
  Duration time = Duration.zero;

  /// Runs [body] counting its queries.
  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: this});

  /// Counts a query.
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

  /// [sql] with its literals replaced, to group similar queries. An
  /// application runs the same few statements over and over, so the last
  /// [fingerprintCacheSize] fingerprints are kept per isolate instead of
  /// running three regular expressions on every query.
  static String fingerprint(String sql) {
    final cached = _fingerprints[sql];
    if (cached != null) {
      return cached;
    }
    final computed = sql
        .replaceAll(_placeholder, '?')
        .replaceAll(_list, '(?)')
        .replaceAll(_space, ' ')
        .trim();
    if (_fingerprints.length >= fingerprintCacheSize) {
      // Statements built with inlined values never repeat: start over
      // rather than track recency on every hit.
      _fingerprints.clear();
    }
    _fingerprints[sql] = computed;
    return computed;
  }

  /// How many fingerprints [fingerprint] keeps per isolate.
  static const int fingerprintCacheSize = 512;

  static final Map<String, String> _fingerprints = <String, String>{};
}

/// Records requests for the dashboard.
final class PulseMiddleware implements Middleware {
  /// Records into [recorder] with [config], skipping the paths in except.
  const PulseMiddleware(this.recorder, this.config, {required this.except});

  /// Receives the measurements.
  final PulseRecorder recorder;

  /// The Pulse settings.
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
