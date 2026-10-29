import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../foundation/application.dart';
import '../foundation/env.dart';
import '../logging/logger.dart';
import '../support/request_id.dart';
import 'http_exceptions.dart';
import 'kernel.dart';
import 'request.dart';
import 'realtime.dart';
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
    this.maxInFlight,
    this.maxQueueDelay,
    this.maxBodyBytes = defaultMaxBodyBytes,
  });

  /// The body limit a request starts with: [Request.defaultMaxBodyBytes]
  /// (50 MiB, the widest limit `BodyLimitsMiddleware` applies).
  static const int defaultMaxBodyBytes = Request.defaultMaxBodyBytes;

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
    int? maxInFlight,
    Duration? maxQueueDelay,
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
      idleTimeout: env.duration(
        'HTTP_IDLE_TIMEOUT',
        const Duration(seconds: 60),
      ),
      embedQueue: embedQueue ?? env.boolean('SERVER_EMBED_QUEUE'),
      embedScheduler: embedScheduler ?? env.boolean('SERVER_EMBED_SCHEDULER'),
      maxInFlight: maxInFlight == null
          ? _maxInFlightFromEnv(env)
          : maxInFlight == 0
          ? null
          : maxInFlight,
      maxQueueDelay: maxQueueDelay == null
          ? _maxQueueDelayFromEnv(env)
          : maxQueueDelay == Duration.zero
          ? null
          : maxQueueDelay,
      maxBodyBytes: _maxBodyFromEnv(env),
    );
  }

  /// `HTTP_MAX_BODY` in bytes: unset means [defaultMaxBodyBytes], `0` no
  /// limit.
  static int? _maxBodyFromEnv(Env env) {
    final value = env.integer('HTTP_MAX_BODY', defaultMaxBodyBytes);
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'HTTP_MAX_BODY',
        'must be a positive number of bytes, or 0 for no limit',
      );
    }
    return value == 0 ? null : value;
  }

  /// `HTTP_MAX_QUEUE_DELAY`: unset, empty or `0` means no limit.
  static Duration? _maxQueueDelayFromEnv(Env env) {
    final value = env.duration('HTTP_MAX_QUEUE_DELAY', Duration.zero);
    return value <= Duration.zero ? null : value;
  }

  /// `HTTP_MAX_IN_FLIGHT`: unset, empty or `0` means no limit.
  static int? _maxInFlightFromEnv(Env env) {
    final value = env.integer('HTTP_MAX_IN_FLIGHT', 0);
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'HTTP_MAX_IN_FLIGHT',
        'must be a positive integer, or 0 for no limit',
      );
    }
    return value == 0 ? null : value;
  }

  final String host;
  final int port;

  /// Number of HTTP worker isolates (`APP_ISOLATES`, `serve --isolates`).
  /// Above 1, `Application.serveWith` runs a supervisor + workers (ADR-004).
  final int isolates;
  final bool shared;

  /// How long a keep-alive connection may sit without a request before
  /// the server closes it (`HTTP_IDLE_TIMEOUT`, 60 s): the bound on idle
  /// sockets a client opens and never uses. A request in progress is
  /// bounded by [requestTimeout] instead.
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

  /// Load shedding (`HTTP_MAX_IN_FLIGHT`, `serve --max-in-flight`): the
  /// most requests one worker isolate handles at once. Beyond it a request
  /// is refused at once with `503 Service Unavailable` and `Retry-After: 1`,
  /// before routing, middleware or a request scope run, so an overloaded
  /// worker fails fast instead of queueing until every client times out.
  /// The health probes are never refused. `null` (the default) sets no
  /// limit. Under a supervisor the limit is per worker, so the server
  /// takes up to `APP_ISOLATES × HTTP_MAX_IN_FLIGHT` requests at once.
  final int? maxInFlight;

  /// Load shedding by event-loop lag (`HTTP_MAX_QUEUE_DELAY`,
  /// `serve --max-queue-delay`): a timer measures how late the worker's
  /// event loop runs it, which is how long a request has been waiting in
  /// the socket and event queues before the engine even sees it. Above this
  /// delay requests are refused with `503` like [maxInFlight]. This is the
  /// limit that catches synchronous work: a handler that only touches
  /// SQLite or the CPU finishes within one event-loop turn, so it never
  /// counts as in flight, and the queue in front of it is invisible to
  /// [maxInFlight]. `null` (the default) turns it off.
  final Duration? maxQueueDelay;

  /// The body limit every request starts with (`HTTP_MAX_BODY`, 50 MiB):
  /// a declared `Content-Length` above it is refused with `413` before
  /// the body is read, and a body that grows past it while read is cut
  /// off. `BodyLimitsMiddleware` and `RouteEntry.bodyLimit` replace it per
  /// content type or route; without them an application still never
  /// buffers an unbounded body in memory. `null` (`HTTP_MAX_BODY=0`) sets
  /// no limit.
  final int? maxBodyBytes;
}

/// Why a production server with one HTTP isolate on a machine with several
/// cores may be undersized, or `null` when it is not the case: one isolate
/// runs one CPU-bound request at a time, so heavy endpoints stop scaling
/// with concurrency. `serve` logs it and `dartisan doctor` reports it.
String? isolateSizingAdvice({
  required bool production,
  required int isolates,
  int? processors,
}) {
  final cores = processors ?? Platform.numberOfProcessors;
  if (!production || isolates != 1 || cores <= 1) {
    return null;
  }
  return 'APP_ISOLATES=1 on $cores cores: one isolate serves one CPU-bound '
      'request at a time. Set APP_ISOLATES to about the number of cores '
      '(Deployment guide, "Concurrency"), after moving state kept in '
      'statics to a shared store, since each isolate has its own memory: '
      "RateLimiter for limits, Cache.store('process') for short-lived "
      'values on one machine, the database or Redis cache for what must '
      'survive a restart (revoked tokens). Keep 1 when instances are '
      'scaled out instead.';
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
    this.onShed,
  });

  final Application app;
  final ServeOptions options;
  final HttpKernel kernel;
  final Logger logger;

  /// Runs inside each request's scope before the kernel (as
  /// `Application.handle`'s `prepare`); the testing toolkit uses it to
  /// authenticate socket requests (`actingAs`).
  final FutureOr<void> Function(Request request)? prepare;

  /// Called for every request refused by load shedding (the application
  /// counts them in `http_requests_shed_total`).
  final void Function()? onShed;

  HttpServer? _server;
  final Completer<void> _done = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> _signals =
      <StreamSubscription<ProcessSignal>>[];
  bool _stopping = false;
  int _inFlight = 0;
  int _shed = 0;
  int _lastShedLogMs = -1;
  late final Set<String> _neverShed = _healthPaths();
  Timer? _lagTimer;
  final Stopwatch _lagClock = Stopwatch();
  int _lagExpectedUs = 0;
  int _lagUs = 0;

  /// How often the lag timer runs; the measured lag is at least this
  /// coarse, so the smallest useful [ServeOptions.maxQueueDelay] is a few
  /// ticks.
  static const Duration lagTick = Duration(milliseconds: 5);

  /// Requests this engine is handling right now (open WebSockets are not
  /// counted once upgraded; see [openWebSockets]).
  int get inFlight => _inFlight;

  /// Requests refused with 503 because [ServeOptions.maxInFlight] or
  /// [ServeOptions.maxQueueDelay] was reached.
  int get shedRequests => _shed;

  /// The event loop's current lag: how late the last lag tick ran, smoothed
  /// over the last few ticks, or how overdue the next tick already is when
  /// that is more. Zero without [ServeOptions.maxQueueDelay].
  Duration get queueDelay => Duration(microseconds: _currentLagUs());

  /// Requests queued behind synchronous work reach [_handle] before the late
  /// tick has run and updated the average, so a tick overdue right now
  /// counts as lag already.
  int _currentLagUs() {
    if (_lagTimer == null) {
      return _lagUs;
    }
    final overdue = _lagClock.elapsedMicroseconds - _lagExpectedUs;
    return overdue > _lagUs ? overdue : _lagUs;
  }

  void _startLagTimer() {
    if (options.maxQueueDelay == null || _lagTimer != null) {
      return;
    }
    _lagClock.start();
    _lagExpectedUs = lagTick.inMicroseconds;
    _lagTimer = Timer.periodic(lagTick, (_) {
      final now = _lagClock.elapsedMicroseconds;
      final late = (now - _lagExpectedUs).clamp(0, 1 << 40);
      // A short moving average: a single late tick (a GC pause) does not
      // shed, a saturated loop does within a few ticks.
      _lagUs = (_lagUs * 3 + late) ~/ 4;
      _lagExpectedUs = now + lagTick.inMicroseconds;
    });
  }

  /// Completes once the server has stopped.
  Future<void> get done => _done.future;

  Set<String> _healthPaths() {
    final health = app.healthPath;
    if (health == null) {
      return const <String>{};
    }
    return <String>{health, '${health == '/' ? '' : health}/ready'};
  }

  /// Whether [httpRequest] must be refused: the limit is reached and the
  /// path is not a health probe (a liveness probe that fails under load
  /// would get the worker restarted, which is the opposite of help).
  bool _mustShed(HttpRequest httpRequest) {
    final limit = options.maxInFlight;
    final delay = options.maxQueueDelay;
    final overloaded =
        (limit != null && _inFlight >= limit) ||
        (delay != null && _currentLagUs() > delay.inMicroseconds);
    return overloaded && !_neverShed.contains(httpRequest.uri.path);
  }

  /// Answers `503` without routing, scope or body read. A body-less
  /// request (most `GET`s) keeps its keep-alive connection, which costs the
  /// server less than a reconnect; one whose body was not read has its
  /// connection closed by `dart:io`, so a client streaming into an
  /// overloaded worker is not kept.
  void _shedRequest(HttpRequest httpRequest) {
    _shed++;
    onShed?.call();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastShedLogMs >= 1000) {
      _lastShedLogMs = now;
      final limit = options.maxInFlight;
      final reason = limit != null && _inFlight >= limit
          ? '$limit requests in flight'
          : 'event loop '
                '${(_currentLagUs() / 1000).toStringAsFixed(0)}ms behind';
      logger.warning(
        'Load shedding: $reason; refused '
        '${httpRequest.method} ${httpRequest.uri.path} with 503 '
        '($_shed refused so far).',
      );
    }
    final response = httpRequest.response
      ..statusCode = HttpStatus.serviceUnavailable
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.retryAfterHeader, '1')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write('{"message":"Service Unavailable"}');
    unawaited(
      response.close().catchError((Object _) {
        // Client gone.
      }),
    );
  }

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
    _startLagTimer();
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

  final Set<WebSocket> _sockets = <WebSocket>{};

  /// Open WebSocket connections on this engine.
  int get openWebSockets => _sockets.length;

  /// Upgrades [httpRequest] (its middleware has passed); null when it is
  /// not a WebSocket request, which gets `426 Upgrade Required`, or the
  /// upgrade fails.
  Future<WebSocket?> _upgrade(
    HttpRequest httpRequest,
    Request request,
    Response response,
    String id,
  ) async {
    if (!WebSocketTransformer.isUpgradeRequest(httpRequest) || _stopping) {
      final refusal = Response.json(const <String, Object?>{
        'message': 'Upgrade Required',
      }, status: 426).withHeader('upgrade', 'websocket');
      try {
        await refusal.writeTo(httpRequest.response);
      } catch (_) {
        // Client gone.
      }
      await kernel.terminate(request, refusal);
      return null;
    }
    try {
      return await WebSocketTransformer.upgrade(
        httpRequest,
        compression: response.webSocketCompression
            ? CompressionOptions.compressionDefault
            : CompressionOptions.compressionOff,
        // A frame above it fails the connection as it arrives, instead of
        // being buffered whole first.
        maxPayloadLength: response.webSocketMaxPayloadBytes,
      );
    } catch (error) {
      logger.warning('WebSocket upgrade failed for request $id: $error');
      return null;
    }
  }

  /// Runs [handler] in the request's scope until [socket] closes. It holds
  /// no [HttpRequest]: an idle connection keeps only what it needs.
  Future<void> _session(
    WebSocket socket,
    Request request,
    Response response,
    WebSocketHandler handler,
    String id,
  ) async {
    _sockets.add(socket);
    logger.info(
      '${request.method} ${request.path} 101 (WebSocket)',
      <String, Object?>{'request_id': id},
    );
    try {
      await handler(socket, request);
      await socket.done;
    } catch (error, stackTrace) {
      logger.error(
        'WebSocket handler failed for request $id',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'request_id': id},
      );
      await socket.close(WebSocketStatus.internalServerError);
    } finally {
      _sockets.remove(socket);
      await kernel.terminate(request, response);
    }
  }

  /// Stops accepting connections, lets in-flight requests finish (up to
  /// [ServeOptions.shutdownTimeout]) and completes [done].
  Future<void> stop({bool force = false}) async {
    if (_stopping) {
      return done;
    }
    _stopping = true;
    app.markDraining();
    _lagTimer?.cancel();
    _lagTimer = null;
    for (final subscription in _signals) {
      await subscription.cancel();
    }
    _signals.clear();
    // Open WebSockets would hold the shutdown until its timeout: tell
    // clients the server is going away so they reconnect elsewhere.
    for (final socket in _sockets.toList()) {
      unawaited(
        socket.close(WebSocketStatus.goingAway, 'Server shutting down'),
      );
    }
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

  /// Answers a request that could not be turned into a [Request] (see
  /// [Request.fromHttpRequest]) with its [HttpException] status, or 400, and
  /// closes the connection: nothing of it was read or trusted.
  void _rejectMalformed(HttpRequest httpRequest, String id, Object error) {
    final status = error is HttpException
        ? error.status
        : HttpStatus.badRequest;
    final message = error is HttpException && status < 500
        ? error.message
        : 'Bad Request';
    logger.warning(
      'Malformed request refused with $status: $error',
      <String, Object?>{'request_id': id},
    );
    try {
      final response = httpRequest.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.connectionHeader, 'close')
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.write(jsonEncode(<String, Object?>{'message': message}));
      unawaited(
        response.close().catchError((Object _) {
          // Client gone.
        }),
      );
    } on Object {
      // Headers already sent or the socket is gone: nothing left to do.
    }
  }

  void _handle(HttpRequest httpRequest) {
    if (_mustShed(httpRequest)) {
      _shedRequest(httpRequest);
      return;
    }
    // The slot is held until the response is written and terminate() has
    // run (deferred work runs on this worker's event loop too), or until a
    // WebSocket upgrade: a session can last hours and holds a socket, not a
    // slot (see [openWebSockets]). Released exactly once on every path.
    _inFlight++;
    var released = false;
    void release() {
      if (!released) {
        released = true;
        _inFlight--;
      }
    }

    final stopwatch = Stopwatch()..start();
    final id = RequestId.generate();
    final Request request;
    try {
      request = Request.fromHttpRequest(httpRequest, id: id);
    } on Object catch (error) {
      // This runs inside the server's listen callback: an error thrown here
      // is uncaught and ends the isolate (the whole process with one
      // isolate, a worker under a supervisor). A request dart:io accepted
      // but the engine cannot represent is a client error: answer it.
      release();
      _rejectMalformed(httpRequest, id, error);
      return;
    }
    request.maxBodyBytes = options.maxBodyBytes;
    // The closure below lives as long as a WebSocket does: it lets go of
    // the HTTP request once the socket has taken over.
    HttpRequest? raw = httpRequest;

    unawaited(
      app.container
          .runScoped<void>(
            'request',
            (scope) async {
              try {
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
                final onSocket = response.webSocket;
                if (onSocket != null) {
                  final socket = await _upgrade(raw!, request, response, id);
                  raw = null;
                  request.detachBody();
                  release();
                  if (socket != null) {
                    await _session(socket, request, response, onSocket, id);
                  }
                  return;
                }
                try {
                  await response.writeTo(raw!.response);
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
              } finally {
                release();
              }
            },
            onUncaughtError: (error, stackTrace) => logger.error(
              'Uncaught asynchronous error in request $id',
              error: error,
              stackTrace: stackTrace,
            ),
          )
          .catchError((Object error, StackTrace stackTrace) {
            release();
            logger.error(
              'Request scope failed for $id',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }
}
