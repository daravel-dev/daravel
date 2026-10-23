/// Testing toolkit for Daravel applications (BLUEPRINT_V2 §7.11).
///
/// [TestClient] drives an [Application] through `Application.handle` without
/// opening sockets; [TestResponse] offers Laravel-style fluent assertions.
library;

import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Sends synthetic requests to an [Application].
final class TestClient {
  TestClient(this.app, {Map<String, String>? defaultHeaders})
    : _defaultHeaders = <String, String>{...?defaultHeaders};

  final Application app;
  final Map<String, String> _defaultHeaders;

  /// Returns a client that always sends [headers].
  TestClient withHeaders(Map<String, String> headers) => TestClient(
    app,
    defaultHeaders: <String, String>{..._defaultHeaders, ...headers},
  );

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
    Map<String, String>? headers,
  }) => send('POST', uri, json: json, form: form, headers: headers);

  Future<TestResponse> put(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, String>? headers,
  }) => send('PUT', uri, json: json, form: form, headers: headers);

  Future<TestResponse> patch(
    String uri, {
    Object? json,
    Map<String, String>? form,
    Map<String, String>? headers,
  }) => send('PATCH', uri, json: json, form: form, headers: headers);

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
    String? body,
    Map<String, String>? headers,
  }) async {
    final request = Request.fake(
      method: method,
      path: uri,
      json: json,
      form: form,
      body: body,
      headers: <String, String>{
        'accept': 'application/json',
        ..._defaultHeaders,
        ...?headers,
      },
    );
    final response = await app.handle(request);
    return TestResponse(
      status: response.status,
      headers: response.headers,
      bodyBytes: await response.bodyBytes(),
      request: request,
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
