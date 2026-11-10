import 'dart:async';
import 'dart:convert';
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
          (Request q) => guard((_) async => (await report()).toJson()),
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

  static ReverbConfig get _config =>
      _container.make<ConfigRepository>().section<ReverbConfig>();

  /// The report the dashboard shows: of `REVERB_METRICS_URL` when set,
  /// else of this process.
  static Future<ReverbReport> report() async {
    final url = _config.metricsUrl;
    if (url == null || url.isEmpty) {
      return ReverbReport.parse(await _container.make<AppMetrics>().render());
    }
    final token = _container
        .make<ConfigRepository>()
        .section<MetricsConfig>()
        .token;
    var request = Http.timeout(const Duration(seconds: 5));
    if (token != null && token.isNotEmpty) {
      request = request.withToken(token);
    }
    final response = await request.get(url);
    if (!response.successful) {
      throw HttpException(
        502,
        'REVERB_METRICS_URL answered ${response.status}.',
      );
    }
    return ReverbReport.parse(response.body);
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
          } on Object catch (error) {
            stats = {'error': '$error'};
          }
          yield SseEvent({
            'stats': stats,
            'at': DateTime.now().millisecondsSinceEpoch,
          }, event: 'update');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }(), heartbeat: null);

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
