import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'config.dart';
import 'report.dart';
import 'server.dart';
import 'ui.dart';

/// The `/reverb` dashboard (Blueprint #135 §3.6, R3b): a page and its JSON
/// API, with `reverb.*` route names.
///
/// Its numbers are a [ReverbReport] of `/metrics`: this process's own
/// ([AppMetrics.render], every isolate merged), or, with
/// `REVERB_METRICS_URL`, those of the `reverb:start` server it names.
/// Outside `APP_ENV=local` and `testing` every endpoint answers 403 until
/// `withReverb(middleware:)` protects it. No secret is ever sent.
abstract final class ReverbDashboard {
  /// Registers the page and the API under [path] behind [middleware].
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
          (Request q) => guard((_) => _stats()),
        ).name('reverb.stats')
        ..get(
          '$api/apps',
          (Request q) => guard((_) => apps()),
        ).name('reverb.apps')
        ..get(
          '$api/stream',
          (Request q) => guard(_stream),
        ).name('reverb.stream')
        ..post(
          '$api/restart',
          (Request q) => guard(_restart),
        ).name('reverb.restart')
        ..get(
          path,
          (Request q) => guard((_) => _page(path, reverbTabs.first)),
        ).name('reverb.index')
        ..get(
          '$path/{view}',
          (Request q) => guard((r) => _page(path, r.param<String>('view'))),
        ).name('reverb.view');
    }, middleware: middleware);
  }

  static final Random _random = Random.secure();

  static Container get _container => Container.current;

  /// How long the dashboard waits for `REVERB_METRICS_URL`.
  static const Duration metricsTimeout = Duration(seconds: 2);

  /// The report the dashboard shows: of `REVERB_METRICS_URL` when set,
  /// else of this process. A server that cannot be read is a
  /// [MetricsUnreachable], whose message names neither the URL nor the
  /// token.
  ///
  /// Read at most once a second per application ([Clock] time), however
  /// many pages and streams ask: one request to `REVERB_METRICS_URL` a
  /// second, not one per open tab. A failure is kept for that second too,
  /// and a read in progress is shared.
  static Future<ReverbReport> report() async {
    final app = _container.make<Application>();
    final now = Clock.now();
    var sample = _samples[app];
    if (sample == null ||
        now.difference(sample.at) >= const Duration(seconds: 1)) {
      // Shared by requests, so it never fails: a future that fails in one
      // request's error zone never hands its error to another request
      // (that one would hang), and one made in another zone would end the
      // isolate. The error is raised below, in the caller's zone.
      final container = app.container;
      sample = (at: now, result: _settled(container));
      _samples[app] = sample;
    }
    final (report, failure) = await sample.result;
    if (failure != null) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
    return report!;
  }

  static Future<(ReverbReport?, (Object, StackTrace)?)> _settled(
    Container container,
  ) async {
    try {
      return (await _read(container), null);
    } on Object catch (error, stackTrace) {
      return (null, (error, stackTrace));
    }
  }

  static final Expando<
    ({DateTime at, Future<(ReverbReport?, (Object, StackTrace)?)> result})
  >
  _samples = Expando('reverb dashboard sample');

  static Future<ReverbReport> _read(Container container) async {
    final config = container.make<ConfigRepository>();
    final url = config.section<ReverbConfig>().metricsUrl;
    if (url == null || url.isEmpty) {
      return ReverbReport.parse(await container.make<AppMetrics>().render());
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const MetricsUnreachable('REVERB_METRICS_URL is not http(s)');
    }
    final token = config.section<MetricsConfig>().token;
    // dart:io directly, redirects not followed: the token goes to the
    // host named, and to no other one a redirect points at.
    final client = HttpClient()..connectionTimeout = metricsTimeout;
    try {
      final int status;
      final String body;
      try {
        final request = await client.getUrl(uri).timeout(metricsTimeout);
        request.followRedirects = false;
        if (token != null && token.isNotEmpty) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final response = await request.close().timeout(metricsTimeout);
        status = response.statusCode;
        body = await utf8.decodeStream(response).timeout(metricsTimeout);
      } on Object {
        throw const MetricsUnreachable('no answer from REVERB_METRICS_URL');
      }
      if (status < 200 || status >= 300) {
        throw MetricsUnreachable('REVERB_METRICS_URL answered $status');
      }
      return ReverbReport.parse(body);
    } finally {
      client.close(force: true);
    }
  }

  /// The applications served, without their secrets: those of
  /// `REVERB_APP_*` and `REVERB_APPS`, or of the `reverb_apps` table.
  static Future<Map<String, Object?>> apps() async {
    final config = _container.make<ConfigRepository>();
    final reverb = config.section<ReverbConfig>();
    final settings = config.section<BroadcastConfig>();
    final own = settings.serves ? BroadcastApp.fromConfig(settings) : null;
    final listed = <BroadcastApp>[];
    if (reverb.source == ReverbAppsSource.database) {
      final rows = await _container
          .make<DatabaseManager>()
          .table('reverb_apps')
          .orderBy('app_id')
          .limit(500)
          .get();
      for (final row in rows) {
        listed.add(
          ReverbConfig.appFromMap({
            for (final MapEntry(:key, :value) in row.entries)
              key:
                  (key == 'allowed_origins' || key == 'rate_limiting') &&
                      value is String &&
                      value.isNotEmpty
                  ? jsonDecode(value)
                  : value,
          }, 'reverb_apps row ${row['app_id']}'),
        );
      }
    } else {
      listed.addAll(reverb.apps);
    }
    return {
      'provider': reverb.source.name,
      'apps': [
        if (own != null) {...own.toPublicMap(), 'settings': true},
        for (final app in listed)
          if (app.id != own?.id) app.toPublicMap(),
      ],
    };
  }

  /// The stats every second, with a random `retry:` (1 to 5 s) so clients
  /// do not all reconnect at once; it ends when the server drains.
  static Future<Object?> _stream(Request request) async =>
      Response.sse(() async* {
        yield SseEvent(
          'connected',
          event: 'hello',
          retry: Duration(milliseconds: 1000 + _random.nextInt(4001)),
        );
        while (true) {
          Object? stats;
          try {
            stats = (await report()).toJson();
          } on MetricsUnreachable catch (error) {
            stats = {'error': 'Metrics unreachable: ${error.reason}.'};
          }
          yield SseEvent({
            'stats': stats,
            'at': DateTime.now().millisecondsSinceEpoch,
          }, event: 'update');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }(), heartbeat: null);

  /// `GET /api/stats`: the report, or `503` with "Metrics unreachable"
  /// when `REVERB_METRICS_URL` cannot be read.
  static Future<Object?> _stats() async {
    try {
      return (await report()).toJson();
    } on MetricsUnreachable catch (error) {
      return Response.json(
        {'message': '$error'},
        status: 503,
        headers: const {'cache-control': 'no-store'},
      );
    }
  }

  /// `reverb:restart` from the page.
  static Future<Object?> _restart(Request request) async {
    final app = _container.make<Application>();
    if (!await requestReverbRestart(app)) {
      return Response.json({
        'message':
            'The queue has no signal store (QUEUE_SIGNAL_STORE): nothing '
            'to tell the servers through.',
      }, status: 409);
    }
    return {'restarting': true};
  }

  /// The page, with a fresh CSP nonce for its inline style and script;
  /// an unknown tab is a 404.
  static Response _page(String base, String tab) {
    if (!reverbTabs.contains(tab)) {
      throw NotFoundHttpException();
    }
    final nonce = base64Url
        .encode(List<int>.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    return Response.html(
      reverbPage(base: base, nonce: nonce, tab: tab).render(),
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

  static Future<Response> _guard(
    bool protected,
    FutureOr<Object?> Function(Request request) body,
  ) async {
    final app = _container.make<ConfigRepository>().section<AppConfig>();
    if (!protected && !app.isLocal && !app.isTesting) {
      return Response.json({
        'message':
            'The Reverb dashboard needs middleware outside local: '
            "withReverb(middleware: ['auth', 'can:viewReverb']).",
      }, status: 403);
    }
    final result = await body(_container.make<Request>());
    return switch (result) {
      final Response response => response,
      _ => Response.json(result, headers: const {'cache-control': 'no-store'}),
    };
  }
}

/// The dashboard could not read the metrics of `REVERB_METRICS_URL`.
final class MetricsUnreachable implements Exception {
  /// Why, without the URL or the token.
  const MetricsUnreachable(this.reason);

  /// Why.
  final String reason;

  @override
  String toString() => 'Metrics unreachable: $reason.';
}
