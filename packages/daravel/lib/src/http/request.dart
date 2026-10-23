import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../foundation/container.dart';
import '../routing/route_entry.dart';
import 'headers.dart';
import 'http_exceptions.dart';

/// Incoming HTTP request (BLUEPRINT_V2 §7.2.2).
///
/// Instances are created by the server engine from `dart:io` requests or by
/// [Request.fake] in tests. The body is read lazily and at most once.
final class Request {
  Request._({
    required this.method,
    required this.uri,
    required this.headers,
    required this.ip,
    required this.id,
    Stream<List<int>>? bodyStream,
    List<int>? bodyBytes,
  }) : _bodyStream = bodyStream,
       _bodyBytes = bodyBytes;

  /// Wraps a `dart:io` request.
  factory Request.fromHttpRequest(
    HttpRequest httpRequest, {
    required String id,
  }) => Request._(
    method: httpRequest.method.toUpperCase(),
    uri: httpRequest.requestedUri,
    headers: Headers.fromHttpHeaders(httpRequest.headers),
    ip: httpRequest.connectionInfo?.remoteAddress.address ?? '',
    id: id,
    bodyStream: httpRequest,
  );

  /// Builds a synthetic request without opening a socket.
  ///
  /// [json] is encoded as the body with `content-type: application/json`,
  /// [form] as `application/x-www-form-urlencoded`, [body] as raw text.
  factory Request.fake({
    String method = 'GET',
    String path = '/',
    Object? json,
    Map<String, String>? form,
    String? body,
    Map<String, String>? headers,
    Map<String, String>? query,
    String ip = '127.0.0.1',
    String? id,
  }) {
    var uri = Uri.parse(
      path.startsWith('/') ? 'http://localhost$path' : 'http://localhost/$path',
    );
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{...uri.queryParameters, ...query},
      );
    }
    final requestHeaders = Headers(headers);
    List<int>? bytes;
    if (json != null) {
      bytes = utf8.encode(jsonEncode(json));
      requestHeaders.set('content-type', 'application/json');
    } else if (form != null) {
      bytes = utf8.encode(Uri(queryParameters: form).query);
      requestHeaders.set('content-type', 'application/x-www-form-urlencoded');
    } else if (body != null) {
      bytes = utf8.encode(body);
    }
    return Request._(
      method: method.toUpperCase(),
      uri: uri,
      headers: requestHeaders,
      ip: ip,
      id: id ?? 'fake-${DateTime.now().microsecondsSinceEpoch}',
      bodyBytes: bytes ?? const <int>[],
    );
  }

  /// Upper-cased HTTP method.
  final String method;

  /// Full request URI.
  final Uri uri;

  /// Request headers.
  final Headers headers;

  /// Remote address (trusted-proxy handling arrives in slice S2).
  final String ip;

  /// Unique request id (also echoed as `x-request-id`).
  final String id;

  /// Arbitrary per-request data shared between middleware and handlers.
  final Map<String, Object?> attributes = <String, Object?>{};

  Stream<List<int>>? _bodyStream;
  List<int>? _bodyBytes;
  Object? _parsedBody;
  bool _bodyParsed = false;

  RouteEntry? _route;
  Map<String, String> _routeParams = const <String, String>{};

  /// Path component of the URI.
  String get path => uri.path;

  /// Single-valued query parameters.
  Map<String, String> get query => uri.queryParameters;

  /// Multi-valued query parameters.
  Map<String, List<String>> get queryMulti => uri.queryParametersAll;

  /// The matched route (set by the kernel).
  RouteEntry? get route => _route;

  /// Raw route parameters (set by the kernel).
  Map<String, String> get routeParams => _routeParams;

  /// Binds the matched route and its parameters. Called by the HTTP kernel.
  void bindRoute(RouteEntry route, Map<String, String> params) {
    _route = route;
    _routeParams = Map.unmodifiable(params);
  }

  /// First value of header [name].
  String? header(String name) => headers.first(name);

  /// Whether the body is JSON.
  bool get isJson => (headers.contentType ?? '').toLowerCase().contains('json');

  /// Whether the client expects a JSON response.
  bool get expectsJson {
    final accept = (headers.first('accept') ?? '').toLowerCase();
    return accept.contains('/json') ||
        accept.contains('+json') ||
        headers.first('x-requested-with') == 'XMLHttpRequest';
  }

  /// Token from an `Authorization: Bearer <token>` header.
  String? bearerToken() {
    final value = headers.first('authorization');
    if (value == null) {
      return null;
    }
    const prefix = 'Bearer ';
    if (!value.startsWith(prefix)) {
      return null;
    }
    final token = value.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  /// Reads the raw body (once; cached).
  Future<List<int>> bytes() async {
    final cached = _bodyBytes;
    if (cached != null) {
      return cached;
    }
    final stream = _bodyStream;
    _bodyStream = null;
    if (stream == null) {
      return _bodyBytes = const <int>[];
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return _bodyBytes = builder.takeBytes();
  }

  /// Parses the body according to its content type:
  /// JSON → decoded value, form → `Map<String, String>`, otherwise the raw
  /// text (or `null` when empty).
  Future<Object?> body() async {
    if (_bodyParsed) {
      return _parsedBody;
    }
    final raw = await bytes();
    _bodyParsed = true;
    if (raw.isEmpty) {
      return _parsedBody = null;
    }
    final contentType = (headers.contentType ?? '').toLowerCase();
    if (contentType.contains('json')) {
      try {
        return _parsedBody = jsonDecode(utf8.decode(raw)) as Object?;
      } on FormatException catch (error) {
        throw BadRequestHttpException('Malformed JSON body: ${error.message}');
      }
    }
    if (contentType.contains('application/x-www-form-urlencoded')) {
      return _parsedBody = Uri.splitQueryString(utf8.decode(raw));
    }
    return _parsedBody = utf8.decode(raw);
  }

  /// Merged input: query parameters overlaid by body fields (body wins).
  Future<Map<String, Object?>> all() async {
    final result = <String, Object?>{...query};
    final parsed = await body();
    if (parsed is Map<String, Object?>) {
      result.addAll(parsed);
    } else if (parsed is Map<Object?, Object?>) {
      parsed.forEach((key, value) => result['$key'] = value);
    }
    return result;
  }

  /// Dot-notation input lookup across body and query (`user.email`).
  Future<T?> input<T>(String key, [T? fallback]) async {
    final value = _dig(await all(), key);
    if (value is T) {
      return value;
    }
    return fallback;
  }

  /// Whether [key] is present in the input (even if empty).
  Future<bool> has(String key) async => _dig(await all(), key) != null;

  /// Typed route parameter. Supports `String`, `int`, `double`, `bool`.
  /// Throws [NotFoundHttpException] when missing or unparsable, so a route
  /// like `/users/{id}` with `id = abc` yields a 404 (Laravel parity).
  T param<T>(String key) {
    final raw = _routeParams[key];
    if (raw == null) {
      throw NotFoundHttpException('Route parameter [$key] is missing.');
    }
    final Object? parsed = switch (T) {
      const (String) => raw,
      const (int) => int.tryParse(raw),
      const (double) => double.tryParse(raw),
      const (bool) => switch (raw.toLowerCase()) {
        'true' || '1' => true,
        'false' || '0' => false,
        _ => null,
      },
      _ => raw,
    };
    if (parsed is T) {
      return parsed;
    }
    throw NotFoundHttpException(
      'Route parameter [$key] with value "$raw" is not a valid $T.',
    );
  }

  /// Resolves [T] from the container of the active request scope.
  T make<T extends Object>({String? name}) =>
      Container.current.make<T>(name: name);

  static Object? _dig(Object? source, String key) {
    Object? current = source;
    for (final segment in key.split('.')) {
      if (current is Map<String, Object?>) {
        current = current[segment];
      } else if (current is Map<Object?, Object?>) {
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

  @override
  String toString() => 'Request($method ${uri.path})';
}
