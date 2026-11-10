import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import '../foundation/container.dart';
import '../foundation/exceptions.dart';
import 'headers.dart';

/// Outgoing HTTP requests, like Laravel's `Http` facade:
///
/// ```dart
/// final response = await Http.withToken(key)
///     .baseUrl('https://api.example.com')
///     .timeout(const Duration(seconds: 10))
///     .retry(3, delay: const Duration(milliseconds: 200))
///     .post('/v1/charges', json: {'amount': 5000});
/// if (response.successful) {
///   final id = response.json('id');
/// }
/// ```
///
/// In tests, [fake] answers requests without the network and records them
/// for assertions.
abstract final class Http {
  /// The client factory of the current container, holding fakes and
  /// settings.
  static HttpClientFactory get factory =>
      Container.current.make<HttpClientFactory>();

  /// A new request to configure.
  static PendingRequest request() => factory.request();

  /// A request whose relative URLs resolve against [url].
  static PendingRequest baseUrl(String url) => request().baseUrl(url);

  /// A request with [headers].
  static PendingRequest withHeaders(Map<String, String> headers) =>
      request().withHeaders(headers);

  /// A request with an `Authorization: <type> <token>` header.
  static PendingRequest withToken(String token, {String type = 'Bearer'}) =>
      request().withToken(token, type: type);

  /// A request with HTTP basic authentication.
  static PendingRequest withBasicAuth(String username, String password) =>
      request().withBasicAuth(username, password);

  /// A request accepting JSON (`Accept: application/json`).
  static PendingRequest acceptJson() => request().acceptJson();

  /// A request sending its body as a form (`application/x-www-form-urlencoded`).
  static PendingRequest asForm() => request().asForm();

  /// A request that fails after [timeout].
  static PendingRequest timeout(Duration timeout) => request().timeout(timeout);

  /// A request retried on connection errors and failed responses (see
  /// [PendingRequest.retry]).
  static PendingRequest retry(
    int times, {
    Duration delay = const Duration(milliseconds: 100),
    bool Function(ClientResponse? response, Object? error)? when,
    Duration Function(int attempt)? backoff,
    double jitter = 0,
    bool honorRetryAfter = false,
    Duration maxRetryAfter = const Duration(seconds: 10),
  }) => request().retry(
    times,
    delay: delay,
    when: when,
    backoff: backoff,
    jitter: jitter,
    honorRetryAfter: honorRetryAfter,
    maxRetryAfter: maxRetryAfter,
  );

  /// Waits of [base], then [factor] times longer after each try, at most
  /// [max]: `retry(5, backoff: Http.exponentialBackoff())` waits 100, 200,
  /// 400 and 800 ms.
  static Duration Function(int attempt) exponentialBackoff({
    Duration base = const Duration(milliseconds: 100),
    Duration max = const Duration(seconds: 10),
    double factor = 2,
  }) => (attempt) {
    final micros =
        base.inMicroseconds * math.pow(factor, attempt < 1 ? 0 : attempt - 1);
    return micros >= max.inMicroseconds
        ? max
        : Duration(microseconds: micros.round());
  };

  /// Laravel's `retry(3, [100, 200, 500])`: the waits in order, the last
  /// one again once they run out.
  static Duration Function(int attempt) backoffSequence(List<Duration> waits) {
    final copy = List<Duration>.unmodifiable(waits);
    return (attempt) => copy.isEmpty
        ? Duration.zero
        : copy[(attempt < 1 ? 1 : attempt).clamp(1, copy.length) - 1];
  }

  /// A `when:` that retries a connection error, `429` and `5xx`, and not
  /// the other client errors, which another try does not change.
  static bool retryOnConnectionOr5xx(ClientResponse? response, Object? error) =>
      error != null ||
      (response != null && (response.status == 429 || response.status >= 500));

  /// A `when:` that retries only when the connection failed.
  static bool retryOnConnectionOnly(ClientResponse? response, Object? error) =>
      error != null;

  /// Sends `GET` [url] with the [query] parameters.
  static Future<ClientResponse> get(
    String url, {
    Map<String, Object?>? query,
  }) => request().get(url, query: query);

  /// Sends `HEAD` [url].
  static Future<ClientResponse> head(
    String url, {
    Map<String, Object?>? query,
  }) => request().head(url, query: query);

  /// Sends `POST` [url] with a body: a map is sent as JSON unless the
  /// request is `asForm`.
  static Future<ClientResponse> post(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => request().post(url, json: json, form: form, body: body);

  /// Sends `PUT` [url] with a body.
  static Future<ClientResponse> put(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => request().put(url, json: json, form: form, body: body);

  /// Sends `PATCH` [url] with a body.
  static Future<ClientResponse> patch(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => request().patch(url, json: json, form: form, body: body);

  /// Sends `DELETE` [url].
  static Future<ClientResponse> delete(
    String url, {
    Object? json,
    Map<String, Object?>? query,
  }) => request().delete(url, json: json, query: query);

  /// Answers requests from [stubs] instead of the network. Keys are URL
  /// patterns (`*` is a wildcard; a scheme is optional, as in Laravel);
  /// values are a [ClientResponse], a [ResponseSequence] or a function of
  /// the [ClientRequest]. Without stubs every request answers 200.
  static HttpFake fake([Map<String, Object> stubs = const {}]) =>
      factory.fake(stubs);

  /// A stubbed response: maps and lists become JSON.
  static ClientResponse response([
    Object? body,
    int status = 200,
    Map<String, String> headers = const {},
  ]) => ClientResponse.fake(body, status: status, headers: headers);

  /// Responses returned in order for repeated requests to one stub.
  static ResponseSequence sequence(List<ClientResponse> responses) =>
      ResponseSequence(responses);

  /// Makes unstubbed requests throw while faking.
  static void preventStrayRequests([bool prevent = true]) =>
      factory.preventStrayRequests(prevent);
}

/// Sends outgoing requests (one pooled `dart:io` client) or answers them
/// from a fake. Registered as a singleton in the application container.
final class HttpClientFactory {
  /// A factory sending through `dart:io`, or through clients from
  /// [clientFactory] in tests.
  /// [random] draws the retry jitter and [sleep] waits between tries;
  /// tests pass their own.
  HttpClientFactory({
    io.HttpClient Function()? clientFactory,
    math.Random? random,
    Future<void> Function(Duration wait)? sleep,
  }) : _clientFactory = clientFactory ?? io.HttpClient.new,
       _random = random ?? math.Random(),
       _sleep = sleep ?? _delay;

  final math.Random _random;
  final Future<void> Function(Duration wait) _sleep;

  static Future<void> _delay(Duration wait) => Future<void>.delayed(wait);

  final io.HttpClient Function() _clientFactory;
  io.HttpClient? _client;
  HttpFake? _fake;
  bool _preventStray = false;

  /// A new request to configure.
  PendingRequest request() => PendingRequest._(this);

  /// Answers matching requests with [stubs] instead of the network:
  /// URL patterns (`*` wildcards) to a [ClientResponse], a
  /// [ResponseSequence], or a function of the [ClientRequest]. Returns the
  /// fake, to assert what was sent.
  HttpFake fake(Map<String, Object> stubs) {
    final fake = _fake ??= HttpFake._();
    fake._stubs.addAll(stubs);
    return fake;
  }

  /// When [prevent], a request no stub matches throws
  /// [StrayRequestException] instead of reaching the network.
  void preventStrayRequests(bool prevent) {
    _preventStray = prevent;
    _fake ??= HttpFake._();
  }

  /// Removes the fake (tests that share an application).
  void restore() {
    _fake = null;
    _preventStray = false;
  }

  /// The largest response body read by default (32 MiB); larger ones throw
  /// [ResponseTooLargeException]. `PendingRequest.maxResponseSize` changes
  /// it per request.
  static const int defaultMaxResponseBytes = 32 * 1024 * 1024;

  /// The body limit of requests that do not set their own; `null` for none.
  int? maxResponseBytes = defaultMaxResponseBytes;

  /// How long opening a connection may take, within the request's own
  /// timeout (10 s, Laravel's `connect_timeout`). Read when the pooled
  /// client is created.
  Duration connectTimeout = const Duration(seconds: 10);

  /// The most connections to one host at once (`null`: no limit); further
  /// requests wait for one. Read when the pooled client is created.
  int? maxConnectionsPerHost;

  Future<ClientResponse> _send(
    ClientRequest request,
    Duration timeout,
    int? maxBytes,
  ) async {
    final fake = _fake;
    if (fake != null) {
      return fake._answer(request, preventStray: _preventStray);
    }
    final client = _client ??= _clientFactory()
      ..idleTimeout = const Duration(seconds: 5)
      ..connectionTimeout = connectTimeout
      ..maxConnectionsPerHost = maxConnectionsPerHost;
    // One deadline for the whole request: each phase gets what is left.
    final elapsed = Stopwatch()..start();
    Duration left() {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('The request ran out of time.', timeout);
      }
      return remaining;
    }

    io.HttpClientRequest? outgoing;
    try {
      final opening = client.openUrl(request.method, request.url);
      try {
        outgoing = await opening.timeout(left());
      } on TimeoutException {
        // The connection may still open: close it then.
        unawaited(
          opening.then<void>((late) => late.abort(), onError: (Object _) {}),
        );
        rethrow;
      }
      for (final MapEntry(:key, :value) in request.headers.entries) {
        for (final item in value) {
          outgoing.headers.add(key, item);
        }
      }
      if (request.body.isNotEmpty) {
        final bytes = utf8.encode(request.body);
        outgoing
          ..contentLength = bytes.length
          ..add(bytes);
      }
      final incoming = await outgoing.close().timeout(left());
      final bytes = await _readBody(
        incoming,
        left(),
        maxBytes,
        request.url,
        outgoing,
      );
      final headers = Headers();
      incoming.headers.forEach((name, values) {
        for (final value in values) {
          headers.add(name, value);
        }
      });
      return ClientResponse(
        incoming.statusCode,
        utf8.decode(bytes, allowMalformed: true),
        headers: headers,
        bodyBytes: bytes,
      );
    } on TimeoutException {
      // Stop the exchange: the server sees the connection close, and no
      // more of the body is read into memory.
      outgoing?.abort();
      throw ConnectionException(
        'Request to ${request.url} timed out after ${timeout.inSeconds}s.',
        isTimeout: true,
      );
    } on io.SocketException catch (error) {
      outgoing?.abort();
      throw ConnectionException(
        'Could not reach ${request.url}: ${error.message}',
      );
    } on io.HttpException catch (error) {
      outgoing?.abort();
      throw ConnectionException(
        'HTTP error for ${request.url}: ${error.message}',
      );
    } on io.IOException catch (error) {
      // TLS failures (HandshakeException, CertificateException) and other
      // I/O errors, so retry() and callers see them as connection errors.
      outgoing?.abort();
      throw ConnectionException('Could not reach ${request.url}: $error');
    }
  }

  /// Reads [incoming] within [timeout], refusing more than [maxBytes]. On
  /// either, the subscription is cancelled and the request aborted, so the
  /// connection closes instead of streaming on into this isolate.
  static Future<Uint8List> _readBody(
    io.HttpClientResponse incoming,
    Duration timeout,
    int? maxBytes,
    Uri url,
    io.HttpClientRequest outgoing,
  ) {
    if (maxBytes != null && incoming.contentLength > maxBytes) {
      // Not a byte of it is read: the socket is closed under the client.
      unawaited(
        incoming.detachSocket().then<void>(
          (socket) => socket.destroy(),
          onError: (Object _) {},
        ),
      );
      throw ResponseTooLargeException(url, maxBytes);
    }
    final done = Completer<Uint8List>();
    final body = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    late final Timer timer;

    void fail(Object error) {
      if (done.isCompleted) {
        return;
      }
      timer.cancel();
      unawaited(subscription.cancel().catchError((Object _) {}));
      outgoing.abort();
      done.completeError(error);
    }

    timer = Timer(
      timeout,
      () => fail(TimeoutException('The response body was too slow.', timeout)),
    );
    subscription = incoming.listen(
      (chunk) {
        body.add(chunk);
        if (maxBytes != null && body.length > maxBytes) {
          fail(ResponseTooLargeException(url, maxBytes));
        }
      },
      onError: (Object error) {
        if (!done.isCompleted) {
          timer.cancel();
          done.completeError(error);
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          timer.cancel();
          done.complete(body.takeBytes());
        }
      },
      cancelOnError: true,
    );
    return done.future;
  }

  /// Closes pooled connections (called when the application shuts down).
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

/// A request being configured (Laravel's `PendingRequest`).
final class PendingRequest {
  PendingRequest._(this._factory);

  final HttpClientFactory _factory;
  String? _baseUrl;
  final Headers _headers = Headers({'user-agent': 'Daravel'});
  Duration _timeout = const Duration(seconds: 30);
  int _tries = 1;
  Duration _retryDelay = Duration.zero;
  bool Function(ClientResponse? response, Object? error)? _retryWhen;
  Duration Function(int attempt)? _retryBackoff;
  double _retryJitter = 0;
  bool _honorRetryAfter = false;
  Duration _maxRetryAfter = const Duration(seconds: 10);
  bool _asForm = false;

  /// Resolves relative URLs against [url].
  PendingRequest baseUrl(String url) {
    _baseUrl = url;
    return this;
  }

  /// Adds [headers].
  PendingRequest withHeaders(Map<String, String> headers) {
    headers.forEach(_headers.set);
    return this;
  }

  /// Sends `Authorization: <type> <token>`.
  PendingRequest withToken(String token, {String type = 'Bearer'}) {
    _headers.set('authorization', '$type $token'.trim());
    return this;
  }

  /// Sends HTTP basic authentication.
  PendingRequest withBasicAuth(String username, String password) {
    _headers.set(
      'authorization',
      'Basic ${base64.encode(utf8.encode('$username:$password'))}',
    );
    return this;
  }

  /// Sets the `User-Agent` header.
  PendingRequest withUserAgent(String userAgent) {
    _headers.set('user-agent', userAgent);
    return this;
  }

  /// Sets the `Accept` header to [contentType].
  PendingRequest accept(String contentType) {
    _headers.set('accept', contentType);
    return this;
  }

  /// Accepts JSON.
  PendingRequest acceptJson() => accept('application/json');

  /// Sends `json:` bodies as JSON (the default).
  PendingRequest asJson() {
    _asForm = false;
    return this;
  }

  /// Sends `json:` maps as `application/x-www-form-urlencoded`.
  PendingRequest asForm() {
    _asForm = true;
    return this;
  }

  /// Fails a request after [timeout]; 30 s by default, as in Laravel. It is
  /// one deadline for connecting, sending and reading the whole body, and
  /// when it passes the connection is closed, so the server stops sending.
  PendingRequest timeout(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  /// Refuses a response body over [bytes] with [ResponseTooLargeException],
  /// closing the connection (`null` for no limit). The default is the
  /// factory's `maxResponseBytes`, 32 MiB.
  PendingRequest maxResponseSize(int? bytes) {
    if (bytes != null && bytes < 0) {
      throw RangeError.range(bytes, 0, null, 'bytes');
    }
    _maxResponseBytes = bytes;
    _maxResponseBytesSet = true;
    return this;
  }

  int? _maxResponseBytes;
  bool _maxResponseBytesSet = false;

  /// Tries up to [times] times in total, waiting [delay] between tries, when
  /// the connection fails or the response is a client or server error (or
  /// when [when] says so: [Http.retryOnConnectionOr5xx] leaves other 4xx
  /// alone). The last response is returned either way; the default retries
  /// every failed response, as Laravel's `Http::retry()` does.
  ///
  /// [backoff] gives the wait after try `attempt` (from 1) instead of
  /// [delay] ([Http.exponentialBackoff], [Http.backoffSequence]); [jitter]
  /// (0 to 1) spreads each wait by up to that fraction either way, so
  /// clients that failed together do not retry together. With
  /// [honorRetryAfter], a `429` or `503` carrying `Retry-After` waits what
  /// it says instead, at most [maxRetryAfter].
  PendingRequest retry(
    int times, {
    Duration delay = const Duration(milliseconds: 100),
    bool Function(ClientResponse? response, Object? error)? when,
    Duration Function(int attempt)? backoff,
    double jitter = 0,
    bool honorRetryAfter = false,
    Duration maxRetryAfter = const Duration(seconds: 10),
  }) {
    if (jitter < 0 || jitter > 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be from 0 to 1');
    }
    _tries = times < 1 ? 1 : times;
    _retryDelay = delay;
    _retryWhen = when;
    _retryBackoff = backoff;
    _retryJitter = jitter;
    _honorRetryAfter = honorRetryAfter;
    _maxRetryAfter = maxRetryAfter;
    return this;
  }

  /// The wait after try [attempt], which got [response].
  Duration _retryWait(int attempt, ClientResponse? response) {
    if (_honorRetryAfter &&
        response != null &&
        (response.status == 429 || response.status == 503)) {
      final asked = _retryAfter(response.header('retry-after'));
      if (asked != null) {
        return asked > _maxRetryAfter ? _maxRetryAfter : asked;
      }
    }
    final wait = _retryBackoff?.call(attempt) ?? _retryDelay;
    if (_retryJitter == 0 || wait <= Duration.zero) {
      return wait;
    }
    final spread = 1 + (_factory._random.nextDouble() * 2 - 1) * _retryJitter;
    return Duration(microseconds: (wait.inMicroseconds * spread).round());
  }

  /// `Retry-After` as seconds or an HTTP date; null when absent or bad.
  static Duration? _retryAfter(String? value) {
    if (value == null) {
      return null;
    }
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final left = io.HttpDate.parse(value.trim()).difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    } on Object {
      return null;
    }
  }

  /// Sends `GET` [url] with the [query] parameters.
  Future<ClientResponse> get(String url, {Map<String, Object?>? query}) =>
      send('GET', url, query: query);

  /// Sends `HEAD` [url].
  Future<ClientResponse> head(String url, {Map<String, Object?>? query}) =>
      send('HEAD', url, query: query);

  /// Sends `POST` [url] with a body.
  Future<ClientResponse> post(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => send('POST', url, json: json, form: form, body: body);

  /// Sends `PUT` [url] with a body.
  Future<ClientResponse> put(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => send('PUT', url, json: json, form: form, body: body);

  /// Sends `PATCH` [url] with a body.
  Future<ClientResponse> patch(
    String url, {
    Object? json,
    Map<String, String>? form,
    String? body,
  }) => send('PATCH', url, json: json, form: form, body: body);

  /// Sends `DELETE` [url].
  Future<ClientResponse> delete(
    String url, {
    Object? json,
    Map<String, Object?>? query,
  }) => send('DELETE', url, json: json, query: query);

  /// Sends the request, retrying as configured.
  Future<ClientResponse> send(
    String method,
    String url, {
    Map<String, Object?>? query,
    Object? json,
    Map<String, String>? form,
    String? body,
  }) async {
    final request = _build(method, url, query, json, form, body);
    for (var attempt = 1; ; attempt++) {
      ClientResponse? response;
      Object? error;
      StackTrace? stackTrace;
      try {
        response = await _factory._send(
          request,
          _timeout,
          _maxResponseBytesSet ? _maxResponseBytes : _factory.maxResponseBytes,
        );
      } on ConnectionException catch (e, s) {
        error = e;
        stackTrace = s;
      }
      final retryable =
          _retryWhen?.call(response, error) ??
          (error != null || response!.failed);
      if (attempt >= _tries || !retryable) {
        if (error != null) {
          Error.throwWithStackTrace(error, stackTrace!);
        }
        return response!;
      }
      final wait = _retryWait(attempt, response);
      if (wait > Duration.zero) {
        await _factory._sleep(wait);
      }
    }
  }

  ClientRequest _build(
    String method,
    String url,
    Map<String, Object?>? query,
    Object? json,
    Map<String, String>? form,
    String? body,
  ) {
    var uri = Uri.parse(url);
    final base = _baseUrl;
    if (!uri.hasScheme && base != null) {
      uri = Uri.parse(
        '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}'
        '/${url.startsWith('/') ? url.substring(1) : url}',
      );
    }
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParametersAll,
          for (final MapEntry(:key, :value) in query.entries)
            if (value != null)
              key: value is Iterable ? [for (final v in value) '$v'] : '$value',
        },
      );
    }
    final headers = Headers();
    for (final MapEntry(:key, :value) in _headers.entries) {
      for (final item in value) {
        headers.add(key, item);
      }
    }
    var payload = body ?? '';
    final formData =
        form ??
        (_asForm && json is Map
            ? {for (final e in json.entries) '${e.key}': '${e.value}'}
            : null);
    if (formData != null) {
      payload = Uri(queryParameters: formData).query;
      headers.set('content-type', 'application/x-www-form-urlencoded');
    } else if (json != null) {
      payload = jsonEncode(json);
      headers.set('content-type', 'application/json');
    }
    return ClientRequest(method.toUpperCase(), uri, headers, payload);
  }
}

/// An outgoing request, as sent (and as recorded by [HttpFake]).
final class ClientRequest {
  /// A request of [method] to [url], as a fake sees it.
  ClientRequest(this.method, this.url, this.headers, this.body);

  /// The HTTP method, upper case.
  final String method;

  /// The full URL.
  final Uri url;

  /// The request headers.
  final Headers headers;

  /// The body as text.
  final String body;

  /// The first value of the header [name], or null.
  String? header(String name) => headers.first(name);

  /// Whether the body is JSON.
  bool get isJson =>
      (headers.first('content-type') ?? '').contains('application/json');

  /// The decoded JSON or form body as a map (empty when there is none).
  Map<String, Object?> data() {
    if (body.isEmpty) {
      return const {};
    }
    if (isJson) {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : {'': decoded};
    }
    return Uri.splitQueryString(body);
  }

  /// A value of the body by dot path (`customer.email`).
  Object? json([String? key]) {
    final decoded = body.isEmpty ? null : jsonDecode(body);
    return key == null ? decoded : _dig(decoded, key);
  }

  @override
  String toString() => '$method $url';
}

/// A response to an outgoing request (Laravel's `Http\Client\Response`).
final class ClientResponse {
  /// A response with [status] and [body]; tests build them for fakes.
  ClientResponse(this.status, this.body, {Headers? headers, this._bodyBytes})
    : headers = headers ?? Headers();

  /// A stubbed response: maps and lists become JSON.
  factory ClientResponse.fake(
    Object? body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) {
    final all = Headers(headers);
    final String text;
    if (body is String) {
      text = body;
    } else if (body == null) {
      text = '';
    } else {
      text = jsonEncode(body);
      if (!all.has('content-type')) {
        all.set('content-type', 'application/json');
      }
    }
    return ClientResponse(status, text, headers: all);
  }

  /// The status code.
  final int status;

  /// The body as text (UTF-8; malformed bytes become U+FFFD).
  final String body;

  final Uint8List? _bodyBytes;

  /// The body as received, for binary responses (an image, a PDF); for a
  /// response built from text, its UTF-8 encoding.
  Uint8List get bodyBytes => _bodyBytes ?? utf8.encode(body);

  /// The response headers.
  final Headers headers;

  /// Whether the status is 2xx.
  bool get successful => status >= 200 && status < 300;

  /// Whether the status is 200.
  bool get ok => status == 200;

  /// Whether the status is 3xx.
  bool get redirect => status >= 300 && status < 400;

  /// Whether the status is 4xx.
  bool get clientError => status >= 400 && status < 500;

  /// Whether the status is 5xx.
  bool get serverError => status >= 500;

  /// Whether the status is 4xx or 5xx.
  bool get failed => status >= 400;

  /// The first value of the header [name], or null.
  String? header(String name) => headers.first(name);

  /// The decoded JSON body, or a value in it by dot path.
  Object? json([String? key, Object? fallback]) {
    final Object? decoded;
    try {
      decoded = body.isEmpty ? null : jsonDecode(body);
    } on FormatException {
      return fallback;
    }
    if (key == null) {
      return decoded ?? fallback;
    }
    return _dig(decoded, key) ?? fallback;
  }

  /// The decoded JSON object (empty when the body is not one).
  Map<String, Object?> jsonMap() {
    final decoded = json();
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  /// Throws [RequestException] on a 4xx or 5xx response.
  ClientResponse throwIfFailed() {
    if (failed) {
      throw RequestException(this);
    }
    return this;
  }

  /// Throws [RequestException] on a 4xx; returns this response otherwise.
  ClientResponse throwIfClientError() => clientError ? throwIfFailed() : this;

  /// Throws [RequestException] on a 5xx; returns this response otherwise.
  ClientResponse throwIfServerError() => serverError ? throwIfFailed() : this;
}

/// Responses handed out in order by one stub.
final class ResponseSequence {
  /// Answers a stubbed URL with [responses] in turn.
  ResponseSequence(List<ClientResponse> responses)
    : _responses = List.of(responses);

  final List<ClientResponse> _responses;
  ClientResponse? _whenEmpty;

  /// What to answer once the sequence is exhausted (otherwise a request
  /// past the end throws).
  ResponseSequence whenEmpty(ClientResponse response) {
    _whenEmpty = response;
    return this;
  }

  /// Whether every response was used.
  bool get isEmpty => _responses.isEmpty;

  /// The next response; throws when there is none left.
  ClientResponse next() {
    if (_responses.isNotEmpty) {
      return _responses.removeAt(0);
    }
    final fallback = _whenEmpty;
    if (fallback == null) {
      throw StateError('The response sequence is empty.');
    }
    return fallback;
  }
}

/// Stubs and the requests sent while faking (`Http.fake()`).
final class HttpFake {
  HttpFake._();

  final Map<String, Object> _stubs = {};

  /// Every request the fake answered, in order.
  final List<ClientRequest> recorded = [];

  ClientResponse _answer(ClientRequest request, {required bool preventStray}) {
    recorded.add(request);
    final url = request.url.toString();
    for (final MapEntry(key: pattern, value: stub) in _stubs.entries) {
      if (!_matches(pattern, url)) {
        continue;
      }
      return switch (stub) {
        final ClientResponse response => response,
        final ResponseSequence sequence => sequence.next(),
        final ClientResponse Function(ClientRequest) callback => callback(
          request,
        ),
        _ => throw ArgumentError.value(stub, pattern, 'Unsupported stub'),
      };
    }
    if (preventStray) {
      throw StrayRequestException(request);
    }
    return ClientResponse(200, '');
  }

  /// Laravel's `Str::is(Str::start($pattern, '*'), $url)`.
  static bool _matches(String pattern, String url) {
    final start = pattern.startsWith('*') ? pattern : '*$pattern';
    final regex = RegExp(
      '^${start.split('*').map(RegExp.escape).join('.*')}\$',
    );
    return regex.hasMatch(url);
  }

  /// Requests matching [test].
  Iterable<ClientRequest> sent([bool Function(ClientRequest)? test]) =>
      test == null ? recorded : recorded.where(test);

  /// Fails unless a request matching [test] was sent.
  void assertSent(bool Function(ClientRequest request) test) {
    if (!recorded.any(test)) {
      throw StateError(
        'No matching request was sent. Sent: ${recorded.join(', ')}',
      );
    }
  }

  /// Fails if a request matching [test] was sent.
  void assertNotSent(bool Function(ClientRequest request) test) {
    final matching = recorded.where(test).toList();
    if (matching.isNotEmpty) {
      throw StateError('Unexpected request sent: ${matching.first}');
    }
  }

  /// Fails unless exactly [count] requests were sent.
  void assertSentCount(int count) {
    if (recorded.length != count) {
      throw StateError('Expected $count request(s), ${recorded.length} sent.');
    }
  }

  /// Fails if any request was sent.
  void assertNothingSent() => assertSentCount(0);
}

/// The server could not be reached, or did not answer in time.
final class ConnectionException extends DaravelException {
  /// The connection failed with [message]; [isTimeout] when it timed out.
  const ConnectionException(super.message, {this.isTimeout = false});

  /// Whether the request was sent and the answer did not come in time: it
  /// may have been processed, unlike a connection that was refused or
  /// reset before anything was sent, so a caller retrying must not
  /// assume it was not.
  final bool isTimeout;
}

/// A response body larger than the request allows
/// (`PendingRequest.maxResponseSize`, `HttpClientFactory.maxResponseBytes`).
/// The connection is closed when it is thrown; it is not retried.
final class ResponseTooLargeException extends DaravelException {
  /// The response from [url] went past [maxBytes].
  ResponseTooLargeException(this.url, this.maxBytes)
    : super('The response from $url is larger than $maxBytes bytes.');

  /// The URL requested.
  final Uri url;

  /// The limit it went past.
  final int maxBytes;
}

/// A 4xx or 5xx response, thrown by [ClientResponse.throwIfFailed].
final class RequestException extends DaravelException {
  /// Thrown by `throw()` and its forms for a failed [response].
  RequestException(this.response)
    : super('HTTP request returned status code ${response.status}.');

  /// The failed response.
  final ClientResponse response;
}

/// A request that matched no stub while stray requests are prevented.
final class StrayRequestException extends DaravelException {
  /// A request no fake matched while stray requests are prevented.
  StrayRequestException(ClientRequest request)
    : super('Attempted request to [${request.url}] without a matching fake.');
}

Object? _dig(Object? source, String key) {
  Object? current = source;
  for (final segment in key.split('.')) {
    if (current is Map) {
      current = current[segment];
    } else if (current is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= current.length) {
        return null;
      }
      current = current[index];
    } else {
      return null;
    }
  }
  return current;
}
