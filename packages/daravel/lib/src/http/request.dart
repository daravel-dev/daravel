import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../foundation/container.dart';
import '../routing/route_entry.dart';
import 'headers.dart';
import 'http_exceptions.dart';

/// Rewrites an input value; used by `TrimStrings` and
/// `ConvertEmptyStringsToNull` style middleware.
typedef InputTransformer = Object? Function(String key, Object? value);

/// Incoming HTTP request (BLUEPRINT_V2 §7.2.2).
///
/// Instances are created by the server engine from `dart:io` requests or by
/// [Request.fake] in tests. The body is read lazily, at most once, and never
/// beyond [maxBodyBytes].
final class Request {
  Request._({
    required this.method,
    required this.uri,
    required this.headers,
    required this.remoteAddress,
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
    remoteAddress: httpRequest.connectionInfo?.remoteAddress.address ?? '',
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
    if (bytes != null && !requestHeaders.has('content-length')) {
      requestHeaders.set('content-length', '${bytes.length}');
    }
    return Request._(
      method: method.toUpperCase(),
      uri: uri,
      headers: requestHeaders,
      remoteAddress: ip,
      id: id ?? 'fake-${DateTime.now().microsecondsSinceEpoch}',
      bodyBytes: bytes ?? const <int>[],
    );
  }

  /// Upper-cased HTTP method.
  final String method;

  /// Full request URI as received by the server.
  final Uri uri;

  /// Request headers.
  final Headers headers;

  /// Address of the TCP peer (a proxy when one is in front of the app).
  final String remoteAddress;

  /// Unique request id (also echoed as `x-request-id`).
  final String id;

  /// Arbitrary per-request data shared between middleware and handlers.
  final Map<String, Object?> attributes = <String, Object?>{};

  /// Maximum body size accepted by [bytes]; `null` means unlimited.
  int? maxBodyBytes;

  /// Maximum JSON nesting depth accepted by [body]; `null` means unlimited.
  int? maxJsonDepth;

  Stream<List<int>>? _bodyStream;
  List<int>? _bodyBytes;
  Object? _parsedBody;
  bool _bodyParsed = false;

  RouteEntry? _route;
  Map<String, String> _routeParams = const <String, String>{};

  String? _forwardedIp;
  List<String> _forwardedIps = const <String>[];
  String? _forwardedScheme;
  String? _forwardedHost;

  final List<InputTransformer> _inputTransformers = <InputTransformer>[];
  final List<FutureOr<void> Function()> _deferred =
      <FutureOr<void> Function()>[];

  /// Path component of the URI.
  String get path => uri.path;

  /// Single-valued query parameters.
  Map<String, String> get query => uri.queryParameters;

  /// Multi-valued query parameters.
  Map<String, List<String>> get queryMulti => uri.queryParametersAll;

  /// Client address. Equals [remoteAddress] unless a trusted proxy supplied
  /// `X-Forwarded-For` (see `TrustProxiesMiddleware`).
  String get ip => _forwardedIp ?? remoteAddress;

  /// Full forwarding chain, client first; `[remoteAddress]` without proxies.
  List<String> get ips =>
      _forwardedIps.isEmpty ? <String>[remoteAddress] : _forwardedIps;

  /// Scheme as seen by the client (`X-Forwarded-Proto` when trusted).
  String get scheme => _forwardedScheme ?? uri.scheme;

  /// Whether the client connection used HTTPS.
  bool get isSecure => scheme == 'https';

  /// Host as seen by the client (`X-Forwarded-Host` when trusted).
  String get host => _forwardedHost ?? uri.host;

  /// Records forwarding information. Called by `TrustProxiesMiddleware`.
  void applyForwarded({
    String? ip,
    List<String>? ips,
    String? scheme,
    String? host,
  }) {
    if (ip != null) {
      _forwardedIp = ip;
    }
    if (ips != null) {
      _forwardedIps = List.unmodifiable(ips);
    }
    if (scheme != null) {
      _forwardedScheme = scheme;
    }
    if (host != null) {
      _forwardedHost = host;
    }
  }

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

  /// Declared `content-length`, if present and valid.
  int? get contentLength {
    final raw = headers.first('content-length');
    return raw == null ? null : int.tryParse(raw);
  }

  /// Whether the body is JSON.
  bool get isJson => (headers.contentType ?? '').toLowerCase().contains('json');

  /// Whether the client expects a JSON response.
  bool get expectsJson {
    final accept = (headers.first('accept') ?? '').toLowerCase();
    return accept.contains('/json') ||
        accept.contains('+json') ||
        headers.first('x-requested-with') == 'XMLHttpRequest';
  }

  /// Whether the client accepts HTML.
  bool get acceptsHtml =>
      (headers.first('accept') ?? '').toLowerCase().contains('text/html');

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

  /// Reads the raw body (once; cached). Throws
  /// [PayloadTooLargeHttpException] when [maxBodyBytes] is exceeded, checking
  /// `content-length` first and the actual stream second.
  Future<List<int>> bytes() async {
    final cached = _bodyBytes;
    if (cached != null) {
      _enforceLimit(cached.length);
      return cached;
    }
    final declared = contentLength;
    if (declared != null) {
      _enforceLimit(declared);
    }
    final stream = _bodyStream;
    _bodyStream = null;
    if (stream == null) {
      return _bodyBytes = const <int>[];
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
      _enforceLimit(builder.length);
    }
    return _bodyBytes = builder.takeBytes();
  }

  void _enforceLimit(int size) {
    final limit = maxBodyBytes;
    if (limit != null && size > limit) {
      throw PayloadTooLargeHttpException(
        'Request body exceeds the limit of $limit bytes.',
      );
    }
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
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(raw)) as Object?;
      } on FormatException catch (error) {
        throw BadRequestHttpException('Malformed JSON body: ${error.message}');
      }
      final depthLimit = maxJsonDepth;
      if (depthLimit != null && _depth(decoded) > depthLimit) {
        throw BadRequestHttpException(
          'JSON body nesting exceeds the limit of $depthLimit levels.',
        );
      }
      return _parsedBody = decoded;
    }
    if (contentType.contains('application/x-www-form-urlencoded')) {
      return _parsedBody = Uri.splitQueryString(utf8.decode(raw));
    }
    return _parsedBody = utf8.decode(raw);
  }

  /// Registers a transformer applied to every input value returned by
  /// [all] and [input] (strings are visited recursively inside maps/lists).
  void addInputTransformer(InputTransformer transformer) =>
      _inputTransformers.add(transformer);

  /// Merged input: query parameters overlaid by body fields (body wins),
  /// with input transformers applied.
  Future<Map<String, Object?>> all() async {
    final result = <String, Object?>{...query};
    final parsed = await body();
    if (parsed is Map<String, Object?>) {
      result.addAll(parsed);
    } else if (parsed is Map<Object?, Object?>) {
      parsed.forEach((key, value) => result['$key'] = value);
    }
    if (_inputTransformers.isEmpty) {
      return result;
    }
    return _transform(result, '') as Map<String, Object?>;
  }

  Object? _transform(Object? value, String key) {
    if (value is Map<Object?, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': _transform(entry.value, '${entry.key}'),
      };
    }
    if (value is List<Object?>) {
      return <Object?>[for (final item in value) _transform(item, key)];
    }
    var current = value;
    for (final transformer in _inputTransformers) {
      current = transformer(key, current);
    }
    return current;
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

  /// Schedules [callback] to run after the response has been sent
  /// (Laravel's `defer()` helper); errors are reported, never surfaced to
  /// the client.
  void defer(FutureOr<void> Function() callback) => _deferred.add(callback);

  /// Deferred callbacks registered with [defer]. Consumed by the kernel.
  List<FutureOr<void> Function()> takeDeferred() {
    final callbacks = List<FutureOr<void> Function()>.of(_deferred);
    _deferred.clear();
    return callbacks;
  }

  final Map<String, Object?> _bindings = <String, Object?>{};

  /// Stores the object bound to route parameter [param]. Called by the router.
  void setBinding(String param, Object? value) => _bindings[param] = value;

  /// The object bound to route parameter [param] (see `Router.bind`).
  /// Throws [StateError] when nothing was bound.
  T binding<T>(String param) {
    if (!_bindings.containsKey(param)) {
      throw StateError('No binding resolved for route parameter [$param].');
    }
    return _bindings[param] as T;
  }

  static int _depth(Object? value) {
    if (value is Map<Object?, Object?>) {
      var max = 0;
      for (final child in value.values) {
        final depth = _depth(child);
        if (depth > max) {
          max = depth;
        }
      }
      return max + 1;
    }
    if (value is List<Object?>) {
      var max = 0;
      for (final child in value) {
        final depth = _depth(child);
        if (depth > max) {
          max = depth;
        }
      }
      return max + 1;
    }
    return 0;
  }

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
