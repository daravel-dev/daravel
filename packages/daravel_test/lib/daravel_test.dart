/// Testing toolkit for Daravel applications (BLUEPRINT_V2 §7.11).
///
/// [TestClient] drives an [Application] through `Application.handle`, or
/// through a real `ServerEngine` socket ([TestTransport.socket]);
/// [TestResponse] offers Laravel-style fluent assertions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'src/cookie_jar.dart';

export 'src/architecture.dart';
export 'src/cookie_jar.dart';
export 'src/database.dart';
export 'src/dns.dart';
export 'src/form_request.dart';
export 'src/process.dart';
export 'src/test_app.dart';
export 'src/time.dart';

/// How a [TestClient] reaches the application.
enum TestTransport {
  /// `Application.handle` in the test's isolate (fast; the default).
  inProcess,

  /// A real `ServerEngine` on a loopback port and an `HttpClient`: what
  /// `dart:io` does to requests and responses (headers, `HEAD`, lengths,
  /// compression) is part of the test.
  socket;

  /// `DARAVEL_TEST_TRANSPORT=socket` runs every suite over the socket.
  static TestTransport get fromEnvironment =>
      Platform.environment['DARAVEL_TEST_TRANSPORT'] == 'socket'
      ? socket
      : inProcess;
}

/// Sends synthetic requests to an [Application].
final class TestClient {
  /// A client calling [app] in process, without a socket.
  TestClient(
    this.app, {
    Map<String, String>? defaultHeaders,
    this.user,
    this.guard,
    this.handleExceptions = true,
    TestTransport? transport,
    this.cookieJar,
    this.followRedirects = false,
  }) : _defaultHeaders = <String, String>{...?defaultHeaders},
       transport = transport ?? TestTransport.fromEnvironment,
       _cookies = const <String, String>{},
       _unencryptedCookies = const <String, String>{},
       _session = null,
       _xsrf = true;

  TestClient._with(
    this.app, {
    required this._defaultHeaders,
    required this.user,
    required this.guard,
    required this.handleExceptions,
    required this.transport,
    required this.cookieJar,
    required this.followRedirects,
    required this._cookies,
    required this._unencryptedCookies,
    required this._session,
    required this._xsrf,
  });

  /// The application under test.
  final Application app;
  final Map<String, String> _defaultHeaders;

  /// The cookies kept between requests, as a browser keeps them (see
  /// [browser]); `null` when every request starts without cookies.
  final CookieJar? cookieJar;

  /// Whether a redirect is followed with a `GET` until a response that is
  /// not one (see [followingRedirects]).
  final bool followRedirects;

  final Map<String, String> _cookies;
  final Map<String, String> _unencryptedCookies;
  final _SessionSeed? _session;
  final bool _xsrf;

  /// In process or over a socket (see [TestTransport]).
  final TestTransport transport;

  /// User authenticated for every request (see [actingAs]).
  final Authenticatable? user;

  /// Guard [user] is set on (`null` = the default guard).
  final String? guard;

  /// When false, exceptions propagate to the test instead of being
  /// rendered (see [withoutExceptionHandling]).
  final bool handleExceptions;

  TestClient _copy({
    Map<String, String>? headers,
    Authenticatable? user,
    String? guard,
    bool? handleExceptions,
    CookieJar? cookieJar,
    bool? followRedirects,
    Map<String, String>? cookies,
    Map<String, String>? unencryptedCookies,
    _SessionSeed? session,
    bool? xsrf,
  }) => TestClient._with(
    app,
    defaultHeaders: <String, String>{..._defaultHeaders, ...?headers},
    user: user ?? this.user,
    guard: guard ?? this.guard,
    handleExceptions: handleExceptions ?? this.handleExceptions,
    transport: transport,
    cookieJar: cookieJar ?? this.cookieJar,
    followRedirects: followRedirects ?? this.followRedirects,
    cookies: <String, String>{..._cookies, ...?cookies},
    unencryptedCookies: <String, String>{
      ..._unencryptedCookies,
      ...?unencryptedCookies,
    },
    session: session ?? _session,
    xsrf: xsrf ?? _xsrf,
  );

  /// Returns a client that behaves like a browser: it keeps the cookies
  /// the application sets (the session, `XSRF-TOKEN`, remember-me) in a
  /// [CookieJar] and sends them back, asks for HTML instead of JSON (a
  /// request with a JSON body still asks for JSON), and sends the
  /// `XSRF-TOKEN` cookie back as the `X-XSRF-TOKEN` header on `POST`,
  /// `PUT`, `PATCH` and `DELETE`, as Axios does, so `VerifyCsrfToken`
  /// accepts form posts. With [xsrf] false no header is added, to test the
  /// `419` of a missing token.
  ///
  /// Laravel needs none of this: its session store outlives a request in a
  /// test and `VerifyCsrfToken` skips unit tests. Daravel reads the
  /// session from the cookie on every request and checks CSRF in tests
  /// too, as a browser would meet it.
  ///
  /// Copies of the returned client ([withHeaders], [actingAs], ...) share
  /// its jar; call `browser()` again for a second browser.
  TestClient browser({bool xsrf = true}) =>
      _copy(cookieJar: CookieJar(), xsrf: xsrf);

  /// Returns a client that follows redirects with `GET` requests and
  /// returns the last response (Laravel `followingRedirects`). With a
  /// [browser] client the cookies of every hop are kept.
  TestClient followingRedirects() => _copy(followRedirects: true);

  /// Returns a client that sends cookie [name] with [value] on every
  /// request, encrypted as `EncryptCookies` expects (Laravel `withCookie`):
  /// `Crypt` with the application key, behind Laravel's `CookieValuePrefix`.
  TestClient withCookie(String name, String value) =>
      withCookies(<String, String>{name: value});

  /// [withCookie] for each entry of [cookies] (Laravel `withCookies`).
  TestClient withCookies(Map<String, String> cookies) =>
      _copy(cookies: cookies);

  /// Returns a client that sends cookie [name] with [value] as it is
  /// (Laravel `withUnencryptedCookie`), for cookies `EncryptCookies` leaves
  /// alone or an application without it.
  TestClient withUnencryptedCookie(String name, String value) =>
      withUnencryptedCookies(<String, String>{name: value});

  /// [withUnencryptedCookie] for each entry of [cookies].
  TestClient withUnencryptedCookies(Map<String, String> cookies) =>
      _copy(unencryptedCookies: cookies);

  /// Returns a client whose session holds [data] (Laravel `withSession`):
  /// the session middleware (`daravel_session`'s `web` group) puts each
  /// entry into the session it starts. A [browser] client seeds the
  /// session of its next request only, which then lives on in the cookie;
  /// any other client seeds every request, since each one starts a new
  /// session.
  TestClient withSession(Map<String, Object?> data) => _copy(
    session: _SessionSeed(<String, Object?>{...?_session?.data, ...data}),
  );

  /// Returns a client that always sends [headers].
  TestClient withHeaders(Map<String, String> headers) =>
      _copy(headers: headers);

  /// Authenticates every request as [user] on [guard] without tokens
  /// (Laravel `actingAs`).
  TestClient actingAs(Authenticatable user, {String? guard}) =>
      _copy(user: user, guard: guard);

  /// Lets exceptions reach the test (Laravel `withoutExceptionHandling`),
  /// which shows the real stack trace instead of a 500 body.
  TestClient withoutExceptionHandling() => _copy(handleExceptions: false);

  /// Sends a JSON request with any [method] (`$this->json(...)`).
  Future<TestResponse> json(String method, String uri, [Object? body]) =>
      send(method.toUpperCase(), uri, json: body);

  /// Returns a client that sends `Authorization: Bearer <token>`.
  TestClient withToken(String token) =>
      withHeaders(<String, String>{'authorization': 'Bearer $token'});

  /// Sends `GET` [uri].
  Future<TestResponse> get(String uri, {Map<String, String>? headers}) =>
      send('GET', uri, headers: headers);

  /// Sends `HEAD` [uri].
  Future<TestResponse> head(String uri, {Map<String, String>? headers}) =>
      send('HEAD', uri, headers: headers);

  /// Sends `OPTIONS` [uri].
  Future<TestResponse> options(String uri, {Map<String, String>? headers}) =>
      send('OPTIONS', uri, headers: headers);

  /// Sends `POST` [uri] with a JSON or form body.
  Future<TestResponse> post(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    Map<String, String>? headers,
  }) =>
      send('POST', uri, json: json, form: form, files: files, headers: headers);

  /// Sends `PUT` [uri] with a body.
  Future<TestResponse> put(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    Map<String, String>? headers,
  }) =>
      send('PUT', uri, json: json, form: form, files: files, headers: headers);

  /// Sends `PATCH` [uri] with a body.
  Future<TestResponse> patch(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    Map<String, String>? headers,
  }) => send(
    'PATCH',
    uri,
    json: json,
    form: form,
    files: files,
    headers: headers,
  );

  /// Sends `DELETE` [uri].
  Future<TestResponse> delete(
    String uri, {
    Object? json,
    Map<String, String>? headers,
  }) => send('DELETE', uri, json: json, headers: headers);

  /// The `Accept` header of a [browser] page request.
  static const String browserAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  /// The most redirects [followingRedirects] follows for one request.
  static const int maxRedirects = 20;

  /// Sends a request. JSON requests automatically ask for JSON responses,
  /// and so does every request of a client that is not a [browser].
  Future<TestResponse> send(
    String method,
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    String? body,
    Map<String, String>? headers,
  }) async {
    var response = await _send(
      method,
      uri,
      json: json,
      form: form,
      files: files,
      body: body,
      headers: headers,
    );
    if (!followRedirects) {
      return response;
    }
    for (var hops = 0; ; hops++) {
      final location = response.headers.first('location');
      if (!_followable.contains(response.status) || location == null) {
        return response;
      }
      if (hops == maxRedirects) {
        fail(
          'More than $maxRedirects redirects from $method $uri; the last '
          'one went to $location.',
        );
      }
      final target = response.request.uri.resolve(location);
      response = await _send(
        'GET',
        target.hasQuery ? '${target.path}?${target.query}' : target.path,
      );
    }
  }

  /// The redirects [followingRedirects] follows.
  static const Set<int> _followable = {301, 302, 303, 307, 308};

  Future<TestResponse> _send(
    String method,
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    String? body,
    Map<String, String>? headers,
  }) async {
    final jar = cookieJar;
    final target = Uri.parse(
      uri.startsWith('/') ? 'http://localhost$uri' : 'http://localhost/$uri',
    );
    final requestHeaders = <String, String>{
      'accept': jar == null || json != null
          ? 'application/json'
          : browserAccept,
      ..._defaultHeaders,
      ...?headers,
    };
    final cookies = await _cookiePairs(target);
    if (cookies.isNotEmpty) {
      final own = requestHeaders.remove('cookie');
      requestHeaders['cookie'] = [...cookies, ?own].join('; ');
    }
    final xsrfCookie = jar?['XSRF-TOKEN'];
    if (_xsrf &&
        xsrfCookie != null &&
        !const {'GET', 'HEAD', 'OPTIONS'}.contains(method.toUpperCase()) &&
        !requestHeaders.containsKey('x-xsrf-token') &&
        !requestHeaders.containsKey('x-csrf-token')) {
      requestHeaders['x-xsrf-token'] = xsrfCookie;
    }
    final seed = _session;
    final Map<String, Object?>? sessionData;
    if (seed != null && (jar == null || !seed.applied)) {
      sessionData = seed.data;
      if (jar != null) {
        seed.applied = true;
      }
    } else {
      sessionData = null;
    }
    final request = Request.fake(
      method: method,
      path: uri,
      json: json,
      form: form,
      files: files,
      body: body,
      headers: requestHeaders,
    );
    final TestResponse response;
    // Exceptions cannot cross a socket: withoutExceptionHandling stays in
    // process.
    // Header values HttpClient refuses to send (non-ASCII, control
    // characters, e.g. from fuzzing) are tested in process too.
    if (transport == TestTransport.socket &&
        handleExceptions &&
        _sendable(request.headers)) {
      response = await _SocketHarness.of(app)
          .send(request, user, guard, sessionData);
    } else {
      if (!handleExceptions) {
        request.attributes[ExceptionHandler.rethrowAttribute] = true;
      }
      final capture = _Capture();
      final handled = await app.handle(
        request,
        prepare: () => capture.prepare(request, user, guard, sessionData),
      );
      response = capture.response(
        status: handled.status,
        headers: handled.headers,
        bodyBytes: await handled.bodyBytes(),
        request: request,
      );
    }
    jar?.receive(response.headers.all('set-cookie'), request.uri);
    return response;
  }

  /// The `name=value` pairs of the jar and of [withCookie] /
  /// [withUnencryptedCookie] for [target].
  Future<List<String>> _cookiePairs(Uri target) async {
    final pairs = <String, String>{};
    for (final pair in cookieJar?.pairsFor(target) ?? const <String>[]) {
      final separator = pair.indexOf('=');
      pairs[pair.substring(0, separator)] = pair.substring(separator + 1);
    }
    if (_cookies.isNotEmpty) {
      final encrypted = await app.run(
        () async => <String, String>{
          for (final MapEntry(key: name, :value) in _cookies.entries)
            name: await encryptCookieValue(name, value),
        },
      );
      for (final MapEntry(key: name, :value) in encrypted.entries) {
        pairs[name] = phpRawUrlEncode(value);
      }
    }
    for (final MapEntry(key: name, :value) in _unencryptedCookies.entries) {
      pairs[name] = phpRawUrlEncode(value);
    }
    return [
      for (final MapEntry(key: name, :value) in pairs.entries) '$name=$value',
    ];
  }
}

/// Encrypts [value] as Laravel's `EncryptCookies` does for cookie [name]:
/// `Crypt::encrypt(CookieValuePrefix::create($name, $key).$value, false)`,
/// the prefix being `hash_hmac('sha1', $name.'v2', $key).'|'`. Needs an
/// active application (`app.run`).
Future<String> encryptCookieValue(String name, String value) {
  final encrypter = Crypt.encrypter;
  final prefix = Hmac(sha1, encrypter.key).convert(utf8.encode('${name}v2'));
  return encrypter.encryptString('$prefix|$value');
}

/// The data of [TestClient.withSession], seeded once by a browser client.
final class _SessionSeed {
  _SessionSeed(this.data);

  final Map<String, Object?> data;
  bool applied = false;
}

/// What a test client learns inside the request scope: the server's
/// [Request] (and through it the session) and, when the scope ends, the
/// user each guard resolved.
final class _Capture {
  Request? request;
  Map<String, Authenticatable?>? guards;
  String? defaultGuard;
  final Completer<void> done = Completer<void>();

  /// Runs inside the request scope before the kernel (`Application.handle`
  /// and `ServerEngine`'s `prepare`).
  void prepare(
    Request request,
    Authenticatable? user,
    String? guard,
    Map<String, Object?>? session,
  ) {
    this.request = request;
    final container = Container.current;
    final auth = container.bound<AuthManager>()
        ? container.make<AuthManager>()
        : null;
    if (user != null) {
      final manager = auth ?? container.make<AuthManager>();
      final name = guard ?? manager.defaultGuard;
      manager.guard(name).setUser(user);
      manager.useForRequest(name);
    }
    if (session != null) {
      request.attributes[SessionStore.seedAttribute] = <String, Object?>{
        ...session,
      };
    }
    // Created now, so the guards of the request share it and it is still
    // there when the scope is disposed.
    final state = AuthScope.state();
    container.currentScope?.onDispose(() {
      if (auth != null) {
        defaultGuard = auth.defaultGuard;
        guards = {for (final name in state.resolved) name: state.users[name]};
      }
      if (!done.isCompleted) {
        done.complete();
      }
    });
  }

  TestResponse response({
    required int status,
    required Headers headers,
    required List<int> bodyBytes,
    required Request request,
  }) {
    final session = this.request?.attributes[SessionStore.attribute];
    return TestResponse(
      status: status,
      headers: headers,
      bodyBytes: bodyBytes,
      request: request,
      session: session is SessionStore ? session : null,
      guards: guards,
      defaultGuard: defaultGuard,
    );
  }
}

/// Whether `HttpClient` can send every header value (visible ASCII and tab).
bool _sendable(Headers headers) => headers.entries.every(
  (entry) => entry.value.every(
    (value) => value.codeUnits.every(
      (unit) => unit == 0x09 || (unit >= 0x20 && unit < 0x7F),
    ),
  ),
);

/// One `ServerEngine` per application for [TestTransport.socket], started on
/// the first request and stopped when the test ends.
final class _SocketHarness {
  _SocketHarness._(this.app);

  static final Expando<_SocketHarness> _byApp = Expando('socket harness');

  static _SocketHarness of(Application app) =>
      _byApp[app] ??= _SocketHarness._(app);

  final Application app;
  final Map<
    String,
    (_Capture, Authenticatable?, String?, Map<String, Object?>?)
  >
  _pending = {};
  final Random _random = Random.secure();
  ServerEngine? _engine;
  HttpClient? _client;
  Future<void>? _starting;

  /// Names the request's entry in [_pending]; removed before the
  /// application sees the request, so it sees the same headers as in
  /// process.
  static const String requestHeader = 'x-daravel-test-request';

  Future<void> _start() async {
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
      prepare: (request) {
        final token = request.header(requestHeader);
        final pending = token == null ? null : _pending.remove(token);
        if (pending == null) {
          return;
        }
        request.headers.remove(requestHeader);
        final (capture, user, guard, session) = pending;
        capture.prepare(request, user, guard, session);
      },
    );
    await engine.start();
    _engine = engine;
    // Raw bytes, as in process: no transparent gunzip.
    _client = HttpClient()
      ..userAgent = null
      ..autoUncompress = false;
    addTearDown(_stop);
  }

  Future<void> _stop() async {
    _byApp[app] = null;
    _client?.close(force: true);
    await _engine?.stop();
  }

  Future<TestResponse> send(
    Request fake,
    Authenticatable? user,
    String? guard,
    Map<String, Object?>? session,
  ) async {
    await (_starting ??= _start());
    final url = fake.uri.replace(
      scheme: 'http',
      host: '127.0.0.1',
      port: _engine!.port,
    );
    final outgoing = await _client!.openUrl(fake.method, url);
    outgoing
      ..followRedirects = false
      ..persistentConnection = true;
    // HttpClient asks for gzip on its own; send only what the test sends.
    outgoing.headers.removeAll('accept-encoding');
    // The application sees the same host as in process (`localhost`), so
    // absolute URLs (paginators, redirects) do not depend on the transport.
    outgoing.headers
      ..host = fake.uri.host
      ..port = fake.uri.port;
    for (final MapEntry(key: name, value: values) in fake.headers.entries) {
      if (name == 'host') {
        continue;
      }
      outgoing.headers.removeAll(name);
      for (final value in values) {
        outgoing.headers.add(name, value);
      }
    }
    final capture = _Capture();
    final token = List<int>.generate(
      16,
      (_) => _random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _pending[token] = (capture, user, guard, session);
    outgoing.headers.set(requestHeader, token);
    final body = await fake.bytes();
    if (body.isNotEmpty) {
      outgoing.contentLength = body.length;
      outgoing.add(body);
    }
    final incoming = await outgoing.close();
    final bytes = await incoming.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    final headers = Headers();
    incoming.headers.forEach((name, values) {
      for (final value in values) {
        headers.add(name, value);
      }
    });
    _pending.remove(token);
    if (capture.request != null) {
      // The engine writes the response before it disposes the scope, where
      // the guards are read.
      await capture.done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
    }
    return capture.response(
      status: incoming.statusCode,
      headers: headers,
      bodyBytes: bytes,
      request: fake,
    );
  }
}

/// A captured response with fluent assertions. Every `assert*` method
/// returns `this` for chaining and fails the current test on mismatch.
final class TestResponse {
  /// A response captured by the client.
  TestResponse({
    required this.status,
    required this.headers,
    required this.bodyBytes,
    required this.request,
    this.session,
    this.guards,
    this.defaultGuard,
  });

  /// The status code.
  final int status;

  /// The session of the request as the session middleware left it (after
  /// saving it), or `null` when the route started none (Laravel's
  /// `$response->session()`).
  final SessionStore? session;

  /// The user each guard asked during the request had when the request
  /// ended (`null` for a guest), by guard name; `null` when the
  /// application has no `AuthManager`. A guard nothing asked is missing.
  final Map<String, Authenticatable?>? guards;

  /// The default guard of the application, which [assertAuthenticated]
  /// and [assertGuest] check without a `guard`.
  final String? defaultGuard;

  /// The headers.
  final Headers headers;

  /// The body bytes.
  final List<int> bodyBytes;

  /// The request that produced it.
  final Request request;

  Object? _json;
  bool _jsonDecoded = false;

  /// Body as UTF-8 text.
  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// Decoded JSON body (fails the test when the body is not valid JSON).
  Object? get json {
    if (!_jsonDecoded) {
      try {
        _json = bodyBytes.isEmpty ? null : jsonDecode(body) as Object?;
      } on FormatException catch (error) {
        fail('Response body is not valid JSON (${error.message}):\n$body');
      }
      _jsonDecoded = true;
    }
    return _json;
  }

  /// Decoded JSON body as a map (fails when it is not an object).
  Map<String, Object?> get jsonMap {
    final value = json;
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map<Object?, Object?>) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    fail('Expected a JSON object body but got ${value.runtimeType}:\n$body');
  }

  /// Fails unless the status is [expected].
  TestResponse assertStatus(int expected) {
    if (status != expected) {
      fail(
        'Expected status $expected but received $status for '
        '${request.method} ${request.path}.\nBody: $body',
      );
    }
    return this;
  }

  /// Fails unless the status is 200.
  TestResponse assertOk() => assertStatus(200);

  /// Fails unless the status is 201.
  TestResponse assertCreated() => assertStatus(201);

  /// Fails unless the status is 204.
  TestResponse assertNoContent() => assertStatus(204);

  /// Fails unless the status is 400.
  TestResponse assertBadRequest() => assertStatus(400);

  /// Fails unless the status is 401.
  TestResponse assertUnauthorized() => assertStatus(401);

  /// Fails unless the status is 403.
  TestResponse assertForbidden() => assertStatus(403);

  /// Fails unless the status is 404.
  TestResponse assertNotFound() => assertStatus(404);

  /// Fails unless the status is 405.
  TestResponse assertMethodNotAllowed() => assertStatus(405);

  /// Fails unless the status is 422.
  TestResponse assertUnprocessable() => assertStatus(422);

  /// Fails unless the status is 500.
  TestResponse assertServerError() => assertStatus(500);

  /// Fails unless the header [name] is present (with [value] when given).
  TestResponse assertHeader(String name, [String? value]) {
    final actual = headers.first(name);
    if (actual == null) {
      fail('Header [$name] is missing on the response.');
    }
    if (value != null && actual != value) {
      fail('Header [$name] was "$actual", expected "$value".');
    }
    return this;
  }

  /// Fails if the header [name] is present.
  TestResponse assertHeaderMissing(String name) {
    if (headers.has(name)) {
      fail(
        'Header [$name] was present (${headers.first(name)}) but expected missing.',
      );
    }
    return this;
  }

  /// Asserts that [subset] is contained in the JSON body (Laravel
  /// `assertJson` semantics: maps are matched recursively, lists must match
  /// element-wise, scalars must be equal).
  TestResponse assertJson(Map<String, Object?> subset) {
    final mismatch = _subsetMismatch(json, subset, r'$');
    if (mismatch != null) {
      fail('JSON mismatch: $mismatch\nBody: $body');
    }
    return this;
  }

  /// Asserts that the JSON body equals [expected] exactly.
  TestResponse assertExactJson(Object? expected) {
    expect(json, equals(expected));
    return this;
  }

  /// Asserts the value at dot-notation [path] (`data.0.id`).
  TestResponse assertJsonPath(String path, Object? expected) {
    final actual = _dig(json, path);
    expect(actual, equals(expected), reason: 'JSON path [$path]\nBody: $body');
    return this;
  }

  /// Asserts the list at [path] (or the root) has [count] items.
  TestResponse assertJsonCount(int count, [String? path]) {
    final target = path == null ? json : _dig(json, path);
    if (target is! List<Object?> && target is! Map<Object?, Object?>) {
      fail('JSON at [${path ?? r'$'}] is not a collection.\nBody: $body');
    }
    final actual = target is List<Object?>
        ? target.length
        : (target! as Map<Object?, Object?>).length;
    if (actual != count) {
      fail(
        'Expected $count items at [${path ?? r'$'}] but found $actual.\nBody: $body',
      );
    }
    return this;
  }

  /// Fails unless the body contains [text].
  TestResponse assertSee(String text) {
    if (!body.contains(text)) {
      fail('Expected response body to contain "$text".\nBody: $body');
    }
    return this;
  }

  /// Asserts the JSON has every key of [structure] (`assertJsonStructure`):
  /// a list of keys, nested maps for objects and `'*'` for every element.
  TestResponse assertJsonStructure(Object structure, [String? path]) {
    final mismatch = _structureMismatch(
      path == null ? json : _dig(json, path),
      structure,
      path ?? r'$',
    );
    if (mismatch != null) {
      fail('JSON structure mismatch: $mismatch\nBody: $body');
    }
    return this;
  }

  /// Asserts [fragment] appears as a subset of some object anywhere in the
  /// JSON (`assertJsonFragment`).
  TestResponse assertJsonFragment(Map<String, Object?> fragment) {
    if (!_containsFragment(json, fragment)) {
      fail('JSON fragment $fragment not found.\nBody: $body');
    }
    return this;
  }

  /// Asserts [fragment] appears nowhere in the JSON (`assertJsonMissing`).
  TestResponse assertJsonMissing(Map<String, Object?> fragment) {
    if (_containsFragment(json, fragment)) {
      fail('Unexpected JSON fragment $fragment found.\nBody: $body');
    }
    return this;
  }

  /// Asserts nothing exists at [path].
  TestResponse assertJsonMissingPath(String path) {
    if (_has(json, path)) {
      fail('Unexpected JSON at [$path].\nBody: $body');
    }
    return this;
  }

  /// 422 with errors for [keys] (a list) or exact first messages (a map),
  /// like `assertJsonValidationErrors`.
  TestResponse assertJsonValidationErrors(Object keys) {
    assertUnprocessable();
    final errors = _errors();
    if (keys is Map<Object?, Object?>) {
      for (final entry in keys.entries) {
        final messages = errors['${entry.key}'];
        if (messages == null || !messages.contains(entry.value)) {
          fail(
            'Expected validation error "${entry.value}" for [${entry.key}], '
            'got $messages.\nBody: $body',
          );
        }
      }
      return this;
    }
    for (final key in (keys as List<Object?>).map((k) => '$k')) {
      if (!errors.containsKey(key)) {
        fail(
          'Expected a validation error for [$key]; errors: ${errors.keys}.\nBody: $body',
        );
      }
    }
    return this;
  }

  /// Asserts no validation errors for [keys] (or none at all).
  TestResponse assertJsonMissingValidationErrors([List<String>? keys]) {
    final errors = status == 422 ? _errors() : const <String, List<String>>{};
    final unexpected = keys == null
        ? errors.keys.toList()
        : keys.where(errors.containsKey).toList();
    if (unexpected.isNotEmpty) {
      fail('Unexpected validation errors for $unexpected.\nBody: $body');
    }
    return this;
  }

  /// Request passed validation (`assertValid`).
  TestResponse assertValid([List<String>? keys]) =>
      assertJsonMissingValidationErrors(keys);

  /// Request failed validation for [errors] (`assertInvalid`).
  TestResponse assertInvalid(Object errors) =>
      assertJsonValidationErrors(errors);

  /// A 3xx response, optionally to [location] (`assertRedirect`). As
  /// Laravel's `assertLocation` compares `url()->to()` of both, a path and
  /// the absolute URL of the same page match (`/login` and
  /// `http://localhost/login`).
  TestResponse assertRedirect([String? location]) {
    _assertIsRedirect();
    if (location != null) {
      final actual = headers.first('location') ?? '';
      if (_absoluteUrl(actual) != _absoluteUrl(location)) {
        fail('Expected a redirect to [$location] but it went to [$actual].');
      }
    }
    return this;
  }

  /// A 3xx response whose `Location` contains [fragment]
  /// (`assertRedirectContains`).
  TestResponse assertRedirectContains(String fragment) {
    _assertIsRedirect();
    final actual = headers.first('location') ?? '';
    if (!actual.contains(fragment)) {
      fail('Redirect location [$actual] does not contain [$fragment].');
    }
    return this;
  }

  void _assertIsRedirect() {
    if (status < 300 || status >= 400) {
      fail('Expected a redirect but got HTTP $status.\nBody: $body');
    }
  }

  String _absoluteUrl(String location) {
    final resolved = request.uri.resolve(location);
    final text = resolved.replace(fragment: '').toString();
    final clean = text.endsWith('#')
        ? text.substring(0, text.length - 1)
        : text;
    return clean.endsWith('/') ? clean.substring(0, clean.length - 1) : clean;
  }

  // -- Cookies ----------------------------------------------------------------

  /// The `Set-Cookie` headers of the response, by name (the last wins).
  Map<String, ResponseCookie> get cookies => {
    for (final cookie in headers.all('set-cookie').map(ResponseCookie.parse))
      ?cookie?.name: ?cookie,
  };

  ResponseCookie _cookie(String name) =>
      cookies[name] ??
      fail(
        'Cookie [$name] not present on response; it set '
        '${cookies.keys.toList()}.',
      );

  /// The response sets cookie [name] (`assertCookie`; an encrypted value is
  /// not compared: read it with the next request of a `browser()` client).
  TestResponse assertCookie(String name) {
    _cookie(name);
    return this;
  }

  /// The response sets cookie [name] unencrypted, with [value] when given
  /// (`assertPlainCookie`).
  TestResponse assertPlainCookie(String name, [String? value]) {
    final cookie = _cookie(name);
    if (value != null && cookie.value != value) {
      fail(
        'Cookie [$name] was found, but value [${cookie.value}] does not '
        'match [$value].',
      );
    }
    return this;
  }

  /// The response deletes cookie [name] (`assertCookieExpired`).
  TestResponse assertCookieExpired(String name) {
    if (!_cookie(name).expired) {
      fail(
        'Cookie [$name] is not expired, it expires at '
        '[${_cookie(name).expiresAt(Clock.now())}].',
      );
    }
    return this;
  }

  /// The response sets cookie [name] without deleting it
  /// (`assertCookieNotExpired`).
  TestResponse assertCookieNotExpired(String name) {
    if (_cookie(name).expired) {
      fail('Cookie [$name] is expired.');
    }
    return this;
  }

  /// The response does not set cookie [name] (`assertCookieMissing`).
  TestResponse assertCookieMissing(String name) {
    if (cookies.containsKey(name)) {
      fail('Cookie [$name] is present on response.');
    }
    return this;
  }

  // -- Session ----------------------------------------------------------------

  SessionStore get _session =>
      session ??
      fail(
        'No session on ${request.method} ${request.path}: the route has no '
        "session middleware (daravel_session's `web` group).",
      );

  static void _expectValue(Object? actual, Object expected, String reason) {
    if (expected is bool Function(Object?)) {
      expect(expected(actual), isTrue, reason: reason);
    } else {
      expect(actual, expected, reason: reason);
    }
  }

  /// The session has a non-null [key] (dotted), equal to [value] when
  /// given (`assertSessionHas`). [value] may be a `Matcher` or a
  /// `bool Function(Object?)`, Laravel's closure.
  TestResponse assertSessionHas(String key, [Object? value]) {
    final store = _session;
    if (value == null) {
      if (!store.has(key)) {
        fail('Session is missing expected key [$key].\nSession: ${store.all}');
      }
    } else {
      _expectValue(store.get<Object>(key), value, 'Session key [$key]');
    }
    return this;
  }

  /// [assertSessionHas] for each entry of [values] (`assertSessionHasAll`).
  TestResponse assertSessionHasAll(Map<String, Object?> values) {
    for (final MapEntry(:key, :value) in values.entries) {
      assertSessionHas(key, value);
    }
    return this;
  }

  /// The session lacks [key], or holds something other than [value] when
  /// given (`assertSessionMissing`).
  TestResponse assertSessionMissing(String key, [Object? value]) {
    final store = _session;
    if (value == null) {
      if (store.has(key)) {
        fail('Session has unexpected key [$key].');
      }
    } else if (value is bool Function(Object?)) {
      expect(value(store.get<Object>(key)), isFalse, reason: 'Session [$key]');
    } else {
      expect(store.get<Object>(key), isNot(value), reason: 'Session [$key]');
    }
    return this;
  }

  /// The failed request flashed input [key] (`old('key')`), equal to
  /// [value] when given (`assertSessionHasInput`).
  TestResponse assertSessionHasInput(String key, [Object? value]) {
    final old = _session.old<Object>(key);
    if (value == null) {
      if (old == null) {
        fail('Session is missing expected old input [$key].');
      }
    } else {
      _expectValue(old, value, 'Old input [$key]');
    }
    return this;
  }

  Map<String, List<String>> get _sessionErrors => {
    for (final MapEntry(:key, :value) in _session.errors.entries)
      key: value is List<Object?>
          ? [for (final message in value) '$message']
          : ['$value'],
  };

  static Map<String, Object?> _errorKeys(Object keys) => switch (keys) {
    final String key => {key: null},
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) '$key': value,
    },
    final Iterable<Object?> list => {for (final key in list) '$key': null},
    _ => throw ArgumentError.value(keys, 'keys', 'a String, List or Map'),
  };

  /// The session holds validation errors (flashed by a form post that
  /// failed validation), for every field of [keys] when given
  /// (`assertSessionHasErrors`): a field name, a list of them, or a map of
  /// field to one of its messages.
  TestResponse assertSessionHasErrors([Object keys = const <String>[]]) {
    final errors = _sessionErrors;
    if (errors.isEmpty) {
      fail('Session has no validation errors.\nSession: ${_session.all}');
    }
    for (final MapEntry(key: field, value: message) in _errorKeys(
      keys,
    ).entries) {
      final messages = errors[field];
      if (messages == null) {
        fail('Session missing error: $field. Errors: $errors');
      }
      if (message != null && !messages.contains('$message')) {
        fail('Session error [$field] is $messages, without "$message".');
      }
    }
    return this;
  }

  /// The session holds no validation errors for [keys], or none at all
  /// without [keys] (`assertSessionDoesntHaveErrors`).
  TestResponse assertSessionDoesntHaveErrors([Object keys = const <String>[]]) {
    final wanted = _errorKeys(keys);
    if (wanted.isEmpty) {
      return assertSessionHasNoErrors();
    }
    final errors = _sessionErrors;
    for (final MapEntry(key: field, value: message) in wanted.entries) {
      final messages = errors[field];
      if (messages == null) {
        continue;
      }
      if (message == null || messages.contains('$message')) {
        fail('Session has unexpected error: $field $messages');
      }
    }
    return this;
  }

  /// The session holds no validation errors (`assertSessionHasNoErrors`).
  TestResponse assertSessionHasNoErrors() {
    final errors = _sessionErrors;
    if (errors.isNotEmpty) {
      fail('Session has unexpected errors: $errors');
    }
    return this;
  }

  // -- Authentication -----------------------------------------------------------

  Authenticatable? _guardUser(String? guard, {required bool require}) {
    final known = guards;
    if (known == null) {
      fail('The application has no AuthManager (withAuth).');
    }
    final name = guard ?? defaultGuard!;
    if (!known.containsKey(name)) {
      if (!require) {
        return null;
      }
      fail(
        'The guard [$name] was not asked during ${request.method} '
        '${request.path}, so it did not authenticate anyone. A guard reads '
        'its user when something asks (the auth middleware, Auth.user(), a '
        'login): assert on such a request.',
      );
    }
    return known[name];
  }

  /// The guard [guard] (the default one without it) had a user when the
  /// request ended (`assertAuthenticated`): after a login, or on a route
  /// that resolved the user. Unlike Laravel's, whose guard outlives the
  /// request, a guard nothing asked during the request fails this.
  TestResponse assertAuthenticated({String? guard}) {
    if (_guardUser(guard, require: true) == null) {
      fail('The user is not authenticated.');
    }
    return this;
  }

  /// The guard had no user when the request ended (`assertGuest`): after a
  /// logout, or a guard nothing asked.
  TestResponse assertGuest({String? guard}) {
    final user = _guardUser(guard, require: false);
    if (user != null) {
      fail('The user is authenticated (id ${user.authIdentifier}).');
    }
    return this;
  }

  /// The guard's user is [user]: the same type and identifier
  /// (`assertAuthenticatedAs`).
  TestResponse assertAuthenticatedAs(Authenticatable user, {String? guard}) {
    final actual = _guardUser(guard, require: true);
    if (actual == null) {
      fail('The current user is not authenticated.');
    }
    if (actual.runtimeType != user.runtimeType ||
        '${actual.authIdentifier}' != '${user.authIdentifier}') {
      fail(
        'The authenticated user is ${actual.runtimeType} '
        '#${actual.authIdentifier}, expected ${user.runtimeType} '
        '#${user.authIdentifier}.',
      );
    }
    return this;
  }

  /// Fails if the body contains [text].
  TestResponse assertDontSee(String text) {
    if (body.contains(text)) {
      fail('Expected response body not to contain "$text".\nBody: $body');
    }
    return this;
  }

  Map<String, List<String>> _errors() {
    final errors = jsonMap['errors'];
    if (errors is! Map<Object?, Object?>) {
      fail('Response has no "errors" object.\nBody: $body');
    }
    return <String, List<String>>{
      for (final entry in errors.entries)
        '${entry.key}': [for (final m in entry.value! as List<Object?>) '$m'],
    };
  }

  static String? _structureMismatch(
    Object? actual,
    Object structure,
    String path,
  ) {
    if (structure is List<Object?>) {
      for (final item in structure) {
        final nested = _structureMismatch(actual, item!, path);
        if (nested != null) {
          return nested;
        }
      }
      return null;
    }
    if (structure is Map<Object?, Object?>) {
      for (final entry in structure.entries) {
        final key = '${entry.key}';
        if (key == '*') {
          if (actual is! List<Object?>) {
            return '$path expected a list';
          }
          for (var i = 0; i < actual.length; i++) {
            final nested = _structureMismatch(
              actual[i],
              entry.value!,
              '$path[$i]',
            );
            if (nested != null) {
              return nested;
            }
          }
          continue;
        }
        if (actual is! Map<Object?, Object?> || !actual.containsKey(key)) {
          return '$path.$key is missing';
        }
        final nested = _structureMismatch(
          actual[key],
          entry.value!,
          '$path.$key',
        );
        if (nested != null) {
          return nested;
        }
      }
      return null;
    }
    final key = '$structure';
    if (actual is! Map<Object?, Object?> || !actual.containsKey(key)) {
      return '$path.$key is missing';
    }
    return null;
  }

  static bool _containsFragment(Object? value, Map<String, Object?> fragment) {
    if (value is Map<Object?, Object?>) {
      if (_subsetMismatch(value, fragment, r'$') == null) {
        return true;
      }
      return value.values.any((v) => _containsFragment(v, fragment));
    }
    if (value is List<Object?>) {
      return value.any((v) => _containsFragment(v, fragment));
    }
    return false;
  }

  static bool _has(Object? source, String path) {
    Object? current = source;
    for (final segment in path.split('.')) {
      if (current is Map<Object?, Object?> && current.containsKey(segment)) {
        current = current[segment];
      } else if (current is List<Object?> &&
          int.tryParse(segment) != null &&
          int.parse(segment) >= 0 &&
          int.parse(segment) < current.length) {
        current = current[int.parse(segment)];
      } else {
        return false;
      }
    }
    return true;
  }

  /// Prints status, headers and body (debugging aid).
  TestResponse dump() {
    print('HTTP $status\n${headers.toSingleValueMap()}\n$body');
    return this;
  }

  static String? _subsetMismatch(
    Object? actual,
    Object? expected,
    String path,
  ) {
    if (expected is Map<Object?, Object?>) {
      if (actual is! Map<Object?, Object?>) {
        return '$path expected an object but found ${actual.runtimeType}';
      }
      for (final entry in expected.entries) {
        final key = '${entry.key}';
        if (!actual.containsKey(key)) {
          return '$path.$key is missing';
        }
        final nested = _subsetMismatch(actual[key], entry.value, '$path.$key');
        if (nested != null) {
          return nested;
        }
      }
      return null;
    }
    if (expected is List<Object?>) {
      if (actual is! List<Object?>) {
        return '$path expected a list but found ${actual.runtimeType}';
      }
      if (actual.length != expected.length) {
        return '$path expected ${expected.length} items but found ${actual.length}';
      }
      for (var i = 0; i < expected.length; i++) {
        final nested = _subsetMismatch(actual[i], expected[i], '$path[$i]');
        if (nested != null) {
          return nested;
        }
      }
      return null;
    }
    if (actual != expected) {
      return '$path expected $expected but found $actual';
    }
    return null;
  }

  static Object? _dig(Object? source, String path) {
    Object? current = source;
    for (final segment in path.split('.')) {
      if (current is Map<Object?, Object?>) {
        current = current[segment];
      } else if (current is List<Object?>) {
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
}
