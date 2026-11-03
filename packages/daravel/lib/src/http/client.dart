import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

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

  /// A request retried on connection errors and failed responses.
  static PendingRequest retry(
    int times, {
    Duration delay = const Duration(milliseconds: 100),
    bool Function(ClientResponse? response, Object? error)? when,
  }) => request().retry(times, delay: delay, when: when);

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
  HttpClientFactory({io.HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? io.HttpClient.new;

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

  Future<ClientResponse> _send(ClientRequest request, Duration timeout) async {
    final fake = _fake;
    if (fake != null) {
      return fake._answer(request, preventStray: _preventStray);
    }
    final client = _client ??= _clientFactory()
      ..idleTimeout = const Duration(seconds: 5);
    try {
      final outgoing = await client
          .openUrl(request.method, request.url)
          .timeout(timeout);
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
      final incoming = await outgoing.close().timeout(timeout);
      final body = await utf8.decoder.bind(incoming).join().timeout(timeout);
      final headers = Headers();
      incoming.headers.forEach((name, values) {
        for (final value in values) {
          headers.add(name, value);
        }
      });
      return ClientResponse(incoming.statusCode, body, headers: headers);
    } on TimeoutException {
      throw ConnectionException(
        'Request to ${request.url} timed out after ${timeout.inSeconds}s.',
        isTimeout: true,
      );
    } on io.SocketException catch (error) {
      throw ConnectionException(
        'Could not reach ${request.url}: ${error.message}',
      );
    } on io.HttpException catch (error) {
      throw ConnectionException(
        'HTTP error for ${request.url}: ${error.message}',
      );
    }
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

  /// Fails a request (connect, send and read) after [timeout]; 30 s by
  /// default, as in Laravel.
  PendingRequest timeout(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  /// Tries up to [times] times in total, waiting [delay] between tries, when
  /// the connection fails or the response is a client or server error (or
  /// when [when] says so). The last response is returned either way.
  PendingRequest retry(
    int times, {
    Duration delay = const Duration(milliseconds: 100),
    bool Function(ClientResponse? response, Object? error)? when,
  }) {
    _tries = times < 1 ? 1 : times;
    _retryDelay = delay;
    _retryWhen = when;
    return this;
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
        response = await _factory._send(request, _timeout);
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
      if (_retryDelay > Duration.zero) {
        await Future<void>.delayed(_retryDelay);
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
  ClientResponse(this.status, this.body, {Headers? headers})
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

  /// The body as text.
  final String body;

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
