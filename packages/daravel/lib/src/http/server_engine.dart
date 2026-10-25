import 'dart:async';
import 'dart:io';

import '../foundation/application.dart';
import '../foundation/env.dart';
import '../logging/logger.dart';
import '../support/request_id.dart';
import 'kernel.dart';
import 'request.dart';
import 'response.dart';

/// Options for [Application.serve].
final class ServeOptions {
  const ServeOptions({
    this.host = '127.0.0.1',
    this.port = 8000,
    this.isolates = 1,
    this.shared = true,
    this.idleTimeout = const Duration(seconds: 60),
    this.shutdownTimeout = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 30),
    this.handleSignals = true,
    this.readyTimeout = const Duration(seconds: 30),
    this.embedQueue = false,
    this.embedScheduler = false,
  });

  /// Reads `APP_HOST` / `APP_PORT`, overridable by explicit arguments.
  ///
  /// Without `APP_PORT`, the `PORT` variable injected by Cloud Run, Railway,
  /// Render, Fly.io and Heroku is used, and the host then defaults to
  /// `0.0.0.0` so the platform can reach the server (`APP_HOST` still
  /// wins). Otherwise the defaults are `127.0.0.1:8000`.
  factory ServeOptions.fromEnv(
    Env env, {
    String? host,
    int? port,
    int? isolates,
    bool? embedQueue,
    bool? embedScheduler,
  }) {
    final platformPort = env.has('APP_PORT') ? null : env.maybeString('PORT');
    final platform = platformPort != null && int.tryParse(platformPort) != null;
    return ServeOptions(
      host: host ?? env.string('APP_HOST', platform ? '0.0.0.0' : '127.0.0.1'),
      port:
          port ??
          (platform ? int.parse(platformPort) : env.integer('APP_PORT', 8000)),
      isolates: isolates ?? env.integer('APP_ISOLATES', 1),
      shutdownTimeout: env.duration(
        'SHUTDOWN_TIMEOUT',
        const Duration(seconds: 30),
      ),
      requestTimeout: env.duration(
        'HTTP_REQUEST_TIMEOUT',
        const Duration(seconds: 30),
      ),
      embedQueue: embedQueue ?? env.boolean('SERVER_EMBED_QUEUE'),
      embedScheduler: embedScheduler ?? env.boolean('SERVER_EMBED_SCHEDULER'),
    );
  }

  final String host;
  final int port;

  /// Number of HTTP worker isolates (`APP_ISOLATES`, `serve --isolates`).
  /// Above 1, `Application.serveWith` runs a supervisor + workers (ADR-004).
  final int isolates;
  final bool shared;
  final Duration idleTimeout;
  final Duration shutdownTimeout;

  /// Default handler timeout (routes may override with `RouteEntry.timeout`);
  /// `null` disables it.
  final Duration? requestTimeout;

  /// Whether this engine installs SIGINT/SIGTERM handlers (workers under a
  /// supervisor leave signals to the supervisor).
  final bool handleSignals;

  /// How long the supervisor waits for every worker to bind.
  final Duration readyTimeout;

  /// Runs a queue worker in its own isolate next to the HTTP workers
  /// (`serve --embed-queue`, `SERVER_EMBED_QUEUE`).
  final bool embedQueue;

  /// Runs the scheduler in its own isolate, so no cron entry is needed
  /// (`serve --embed-scheduler`, `SERVER_EMBED_SCHEDULER`).
  final bool embedScheduler;
}

/// Binds the `dart:io` server, wraps every request in a request scope and
/// performs graceful shutdown on `SIGINT` (and `SIGTERM` outside Windows).
final class ServerEngine {
  ServerEngine(
    this.app,
    this.options, {
    required this.kernel,
    required this.logger,
    this.prepare,
  });

  final Application app;
  final ServeOptions options;
  final HttpKernel kernel;
  final Logger logger;

  /// Runs inside each request's scope before the kernel (as
  /// `Application.handle`'s `prepare`); the testing toolkit uses it to
  /// authenticate socket requests (`actingAs`).
  final FutureOr<void> Function(Request request)? prepare;

  HttpServer? _server;
  final Completer<void> _done = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> _signals =
      <StreamSubscription<ProcessSignal>>[];
  bool _stopping = false;

  /// Completes once the server has stopped.
  Future<void> get done => _done.future;

  /// The bound port (useful when `port: 0` was requested).
  int? get port => _server?.port;

  /// Binds and starts listening.
  Future<void> start() async {
    if (_server != null) {
      throw StateError('ServerEngine is already running.');
    }
    final server = await HttpServer.bind(
      options.host,
      options.port,
      shared: options.shared,
    );
    server.idleTimeout = options.idleTimeout;
    // dart:io starts every response from these defaults (X-Frame-Options:
    // SAMEORIGIN, ...) and shares their value lists, so adding to a response
    // header appended to the server's defaults: values piled up across
    // requests. Daravel's middleware sets these headers itself.
    server.defaultResponseHeaders.clear();
    kernel.defaultTimeout = options.requestTimeout;
    _server = server;
    if (options.handleSignals) {
      _installSignalHandlers();
    }
    logger.info(
      'Daravel server listening on http://${options.host}:${server.port}',
    );
    server.listen(
      _handle,
      onError: (Object error, StackTrace stackTrace) => logger.error(
        'HTTP server error',
        error: error,
        stackTrace: stackTrace,
      ),
      onDone: () {
        if (!_done.isCompleted) {
          _done.complete();
        }
      },
    );
  }

  /// Stops accepting connections, lets in-flight requests finish (up to
  /// [ServeOptions.shutdownTimeout]) and completes [done].
  Future<void> stop({bool force = false}) async {
    if (_stopping) {
      return done;
    }
    _stopping = true;
    app.markDraining();
    for (final subscription in _signals) {
      await subscription.cancel();
    }
    _signals.clear();
    final server = _server;
    if (server != null) {
      try {
        try {
          await Future<void>(() async {
            await server.close(force: force);
          }).timeout(options.shutdownTimeout);
        } on TimeoutException {
          logger.warning(
            'Shutdown timeout reached; closing remaining connections.',
          );
          await server.close(force: true);
        }
      } catch (error, stackTrace) {
        logger.error(
          'Error while closing server',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _installSignalHandlers() {
    _signals.add(
      ProcessSignal.sigint.watch().listen((_) => _onSignal('SIGINT')),
    );
    if (!Platform.isWindows) {
      _signals.add(
        ProcessSignal.sigterm.watch().listen((_) => _onSignal('SIGTERM')),
      );
    }
  }

  void _onSignal(String name) {
    logger.info('Received $name, shutting down gracefully...');
    unawaited(stop());
  }

  void _handle(HttpRequest httpRequest) {
    final stopwatch = Stopwatch()..start();
    final id = RequestId.generate();
    final request = Request.fromHttpRequest(httpRequest, id: id);

    unawaited(
      app.container
          .runScoped<void>(
            'request',
            (scope) async {
              scope.put<Request>(request);
              Response response;
              try {
                await prepare?.call(request);
                response = await kernel.handle(request);
              } catch (error, stackTrace) {
                logger.error(
                  'Unhandled error while handling ${request.method} ${request.path}',
                  error: error,
                  stackTrace: stackTrace,
                  context: <String, Object?>{'request_id': id},
                );
                response = Response.json(const <String, Object?>{
                  'message': 'Server Error',
                }, status: 500);
              }
              try {
                await response.writeTo(httpRequest.response);
              } catch (error) {
                logger.warning(
                  'Failed to write response for request $id: $error',
                );
              }
              // Time to response, without terminate() and deferred work.
              final elapsed = stopwatch.elapsedMicroseconds / 1000;
              await kernel.terminate(request, response);
              logger.info(
                '${request.method} ${request.path} ${response.status} '
                '${elapsed.toStringAsFixed(2)}ms',
                <String, Object?>{'request_id': id},
              );
            },
            onUncaughtError: (error, stackTrace) => logger.error(
              'Uncaught asynchronous error in request $id',
              error: error,
              stackTrace: stackTrace,
            ),
          )
          .catchError((Object error, StackTrace stackTrace) {
            logger.error(
              'Request scope failed for $id',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }
}
