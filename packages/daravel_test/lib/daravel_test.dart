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

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

export 'src/architecture.dart';
export 'src/database.dart';
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
  TestClient(
    this.app, {
    Map<String, String>? defaultHeaders,
    this.user,
    this.guard,
    this.handleExceptions = true,
    TestTransport? transport,
  }) : _defaultHeaders = <String, String>{...?defaultHeaders},
       transport = transport ?? TestTransport.fromEnvironment;

  final Application app;
  final Map<String, String> _defaultHeaders;

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
  }) => TestClient(
    app,
    defaultHeaders: <String, String>{..._defaultHeaders, ...?headers},
    user: user ?? this.user,
    guard: guard ?? this.guard,
    handleExceptions: handleExceptions ?? this.handleExceptions,
    transport: transport,
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

  Future<TestResponse> get(String uri, {Map<String, String>? headers}) =>
      send('GET', uri, headers: headers);

  Future<TestResponse> head(String uri, {Map<String, String>? headers}) =>
      send('HEAD', uri, headers: headers);

  Future<TestResponse> options(String uri, {Map<String, String>? headers}) =>
      send('OPTIONS', uri, headers: headers);

  Future<TestResponse> post(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    Map<String, String>? headers,
  }) =>
      send('POST', uri, json: json, form: form, files: files, headers: headers);

  Future<TestResponse> put(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    Map<String, String>? headers,
  }) =>
      send('PUT', uri, json: json, form: form, files: files, headers: headers);

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

  Future<TestResponse> delete(
    String uri, {
    Object? json,
    Map<String, String>? headers,
  }) => send('DELETE', uri, json: json, headers: headers);

  /// Sends a request. JSON requests automatically ask for JSON responses.
  Future<TestResponse> send(
    String method,
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
    String? body,
    Map<String, String>? headers,
  }) async {
    final request = Request.fake(
      method: method,
      path: uri,
      json: json,
      form: form,
      files: files,
      body: body,
      headers: <String, String>{
        'accept': 'application/json',
        ..._defaultHeaders,
        ...?headers,
      },
    );
    // Exceptions cannot cross a socket: withoutExceptionHandling stays in
    // process.
    // Header values HttpClient refuses to send (non-ASCII, control
    // characters, e.g. from fuzzing) are tested in process too.
    if (transport == TestTransport.socket &&
        handleExceptions &&
        _sendable(request.headers)) {
      return _SocketHarness.of(app).send(request, user, guard);
    }
    if (!handleExceptions) {
      request.attributes[ExceptionHandler.rethrowAttribute] = true;
    }
    final actor = user;
    final response = await app.handle(
      request,
      prepare: actor == null
          ? null
          : () {
              final auth = Container.current.make<AuthManager>();
              final name = guard ?? auth.defaultGuard;
              auth.guard(name).setUser(actor);
              auth.useForRequest(name);
            },
    );
    return TestResponse(
      status: response.status,
      headers: response.headers,
      bodyBytes: await response.bodyBytes(),
      request: request,
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
  final Map<String, (Authenticatable, String?)> _actors = {};
  final Random _random = Random.secure();
  ServerEngine? _engine;
  HttpClient? _client;
  Future<void>? _starting;

  static const String actorHeader = 'x-daravel-test-actor';

  Future<void> _start() async {
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
      prepare: (request) {
        final token = request.header(actorHeader);
        final actor = token == null ? null : _actors.remove(token);
        if (actor == null) {
          return;
        }
        final (user, guard) = actor;
        final auth = Container.current.make<AuthManager>();
        final name = guard ?? auth.defaultGuard;
        auth.guard(name).setUser(user);
        auth.useForRequest(name);
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
    if (user != null) {
      final token = List<int>.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      _actors[token] = (user, guard);
      outgoing.headers.set(actorHeader, token);
    }
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
    return TestResponse(
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
  TestResponse({
    required this.status,
    required this.headers,
    required this.bodyBytes,
    required this.request,
  });

  final int status;
  final Headers headers;
  final List<int> bodyBytes;
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

  TestResponse assertStatus(int expected) {
    if (status != expected) {
      fail(
        'Expected status $expected but received $status for '
        '${request.method} ${request.path}.\nBody: $body',
      );
    }
    return this;
  }

  TestResponse assertOk() => assertStatus(200);
  TestResponse assertCreated() => assertStatus(201);
  TestResponse assertNoContent() => assertStatus(204);
  TestResponse assertBadRequest() => assertStatus(400);
  TestResponse assertUnauthorized() => assertStatus(401);
  TestResponse assertForbidden() => assertStatus(403);
  TestResponse assertNotFound() => assertStatus(404);
  TestResponse assertMethodNotAllowed() => assertStatus(405);
  TestResponse assertUnprocessable() => assertStatus(422);
  TestResponse assertServerError() => assertStatus(500);

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

  /// A 3xx response, optionally to [location] (`assertRedirect`).
  TestResponse assertRedirect([String? location]) {
    if (status < 300 || status >= 400) {
      fail('Expected a redirect but got HTTP $status.\nBody: $body');
    }
    if (location != null) {
      assertHeader('location', location);
    }
    return this;
  }

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
