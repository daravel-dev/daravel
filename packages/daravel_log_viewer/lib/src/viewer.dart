import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'entry.dart';
import 'reader.dart';
import 'security.dart';
import 'ui.dart';

/// `withLogViewer()` on the application builder.
extension LogViewerApplicationBuilder on ApplicationBuilder {
  /// Serves the log viewer at [path] (`LOG_VIEWER_PATH`, `/log-viewer`)
  /// behind [middleware]. Outside `APP_ENV=local` and `testing` it answers
  /// 403 until [middleware] protects it (`['auth', 'can:view-logs']`).
  ApplicationBuilder withLogViewer({
    String? path,
    List<Object> middleware = const [],
  }) =>
      withConfig<LogViewerConfig>(LogViewerConfig.fromEnv)
          .withProviders([_LogViewerProvider(path, middleware)]);
}

final class _LogViewerProvider extends ServiceProvider {
  _LogViewerProvider(this.path, this.middleware);
  final String? path;
  final List<Object> middleware;

  @override
  void boot(Container container) {
    final config = container.make<ConfigRepository>();
    LogViewer.routes(
      container.make<Router>(),
      path: path ?? config.get<String>('log_viewer.path', '/log-viewer'),
      middleware: middleware,
    );
  }
}

/// The log viewer's routes and API.
abstract final class LogViewer {
  /// Registers the page and its API under [path].
  static void routes(
    Router router, {
    String path = '/log-viewer',
    List<Object> middleware = const [],
  }) {
    final base = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final protected = middleware.isNotEmpty;
    router.group((r) {
      r
          .get(base, (Request request) => _guard(protected, () => _page(base)))
          .name('log-viewer');
      r.get('$base/api/files', (Request request) => _guard(protected, _files));
      r.get(
        '$base/api/entries',
        (Request request) => _guard(protected, () => _entries(request)),
      );
      r.get(
        '$base/api/tail',
        (Request request) => _guard(protected, () => _tail(request)),
      );
      r.get(
        '$base/api/download',
        (Request request) => _guard(protected, () => _download(request)),
      );
      r.delete(
        '$base/api/files',
        (Request request) => _guard(protected, () => _delete(request)),
      );
    }, middleware: middleware);
  }

  static LogViewerConfig get _config {
    final repository = Container.current.make<ConfigRepository>();
    return repository.hasSection<LogViewerConfig>()
        ? repository.section<LogViewerConfig>()
        : const LogViewerConfig();
  }

  /// The folder of the log files: `LOG_VIEWER_DIRECTORY`, else the
  /// logger's `LOG_PATH`, relative to the application.
  static String get directory {
    final configured = _config.directory;
    final logging = Container.current.make<ConfigRepository>();
    final path =
        configured ??
        (logging.hasSection<LoggingConfig>()
            ? logging.section<LoggingConfig>().path
            : 'storage/logs');
    return p.isAbsolute(path) ? path : p.join(App.instance.basePath, path);
  }

  static Future<Response> _guard(
    bool protected,
    FutureOr<Response> Function() handler,
  ) async {
    final config = _config;
    if (!config.enabled) {
      throw NotFoundHttpException();
    }
    final app = Container.current.make<ConfigRepository>().section<AppConfig>();
    if (!protected && !app.isLocal && !app.isTesting) {
      return Response.json({
        'message':
            'The log viewer needs middleware outside local: '
            "withLogViewer(middleware: ['auth', 'can:view-logs']).",
      }, status: 403);
    }
    try {
      return await handler();
    } on LogFileRefused {
      throw NotFoundHttpException();
    }
  }

  static Response _page(String base) {
    final nonce = base64Url
        .encode(List<int>.generate(18, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    return Response.html(
      logViewerPage(base: base, nonce: nonce, config: _config),
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

  static final math.Random _random = math.Random.secure();

  static Response _json(Object? data, {int status = 200}) => Response.json(
    data,
    status: status,
    headers: {'cache-control': 'no-store'},
  );

  static Response _files() {
    final config = _config;
    return _json({
      'files': [
        for (final file in PathGuard(directory).files())
          {
            'name': p.basename(file.path),
            'size': file.lengthSync(),
            'modified': file.lastModifiedSync().toUtc().toIso8601String(),
          },
      ],
      'allow_download': config.allowDownload,
      'allow_delete': config.allowDelete,
      'per_page': config.perPage,
    });
  }

  static File _file(Request request) {
    final guard = PathGuard(directory);
    final name = request.query['file'];
    if (name == null || name.isEmpty) {
      final newest = guard.files().firstOrNull;
      if (newest == null) {
        throw const LogFileRefused('');
      }
      return newest;
    }
    return guard.resolve(name);
  }

  static Future<Response> _entries(Request request) async {
    final config = _config;
    final file = _file(request);
    final masker = Masker(config.maskKeys);
    final perPage =
        (int.tryParse(request.query['per_page'] ?? '') ?? config.perPage).clamp(
          1,
          500,
        );
    final levels = {
      for (final level in (request.query['levels'] ?? '').split(','))
        if (level.trim().isNotEmpty) level.trim().toLowerCase(),
    };
    final search = request.query['search'];
    final page = await ReverseLogReader(file.path).page(
      before: int.tryParse(request.query['before'] ?? ''),
      limit: perPage,
      filter: LogFilter(levels: levels, search: search),
      maxScanBytes: config.maxScanBytes,
    );
    return _json({
      'file': p.basename(file.path),
      'size': file.lengthSync(),
      'entries': [for (final entry in page.entries) _masked(entry, masker)],
      'next': page.next,
      'scanned_bytes': page.scannedBytes,
    });
  }

  static Map<String, Object?> _masked(LogEntry entry, Masker masker) => {
    ...entry.toJson(),
    'message': masker.text(entry.message),
    'context': masker.json(entry.context),
    'error': entry.error == null ? null : masker.text(entry.error!),
    'trace': entry.trace == null ? null : masker.text(entry.trace!),
  };

  static Response _tail(Request request) {
    final file = _file(request);
    final masker = Masker(_config.maskKeys);
    final from = int.tryParse(request.query['from'] ?? '') ?? file.lengthSync();
    final levels = {
      for (final level in (request.query['levels'] ?? '').split(','))
        if (level.trim().isNotEmpty) level.trim().toLowerCase(),
    };
    final filter = LogFilter(levels: levels, search: request.query['search']);
    return Response.sse(
      ReverseLogReader(file.path)
          .tail(from: from)
          .where(filter.matches)
          .map(
            (entry) => SseEvent(
              jsonEncode(_masked(entry, masker)),
              event: 'entry',
              id: '${entry.offset + entry.length}',
            ),
          ),
      endStreamWith: null,
    );
  }

  static Response _download(Request request) {
    if (!_config.allowDownload) {
      return _json({'message': 'Downloads are disabled.'}, status: 403);
    }
    final file = _file(request);
    final name = p.basename(file.path);
    return Response.stream(
      file.openRead(),
      contentType: 'text/plain; charset=utf-8',
      contentLength: file.lengthSync(),
      headers: {
        'content-disposition': 'attachment; filename="$name"',
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
      },
    );
  }

  static Future<Response> _delete(Request request) async {
    if (!_config.allowDelete) {
      return _json({'message': 'Deleting log files is disabled.'}, status: 403);
    }
    final file = _file(request);
    await file.delete();
    return Response(status: 204);
  }
}
