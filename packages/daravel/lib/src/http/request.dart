import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../foundation/container.dart';
import '../foundation/locale.dart';
import '../routing/route_entry.dart';
import '../validation/validated_data.dart';
import '../validation/validator.dart';
import 'cookies.dart';
import 'headers.dart';
import 'http_exceptions.dart';
import 'multipart.dart';
import 'uploaded_file.dart';

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
    this._bodyStream,
    this._bodyBytes,
  });

  /// Wraps a `dart:io` request.
  ///
  /// Throws [BadRequestHttpException] for a request `dart:io` accepted but
  /// that cannot be represented: `HttpRequest.requestedUri` parses the
  /// `Host`, `X-Forwarded-Host` and `X-Forwarded-Proto` headers with
  /// `Uri.parse` (an unterminated `[::1` or a space throws), and [Headers]
  /// refuses control characters in values. The engine answers 400; without
  /// this the error would escape the server's listen callback and take the
  /// serving isolate down.
  factory Request.fromHttpRequest(
    HttpRequest httpRequest, {
    required String id,
  }) {
    final Uri uri;
    final Headers headers;
    try {
      uri = httpRequest.requestedUri;
      headers = Headers.fromHttpHeaders(httpRequest.headers);
    } on FormatException {
      throw const BadRequestHttpException('Malformed request URI or Host.');
    } on ArgumentError {
      throw const BadRequestHttpException('Malformed request headers.');
    }
    return Request._(
      method: httpRequest.method.toUpperCase(),
      uri: uri,
      headers: headers,
      remoteAddress: httpRequest.connectionInfo?.remoteAddress.address ?? '',
      id: id,
      bodyStream: httpRequest,
    );
  }

  /// Builds a synthetic request without opening a socket.
  ///
  /// [json] is encoded as the body with `content-type: application/json`,
  /// [form] as `application/x-www-form-urlencoded`, [body] as raw text.
  factory Request.fake({
    String method = 'GET',
    String path = '/',
    Object? json,
    Map<String, String>? form,
    Map<String, Object>? files,
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
    if (files != null) {
      // Real multipart bytes, parsed like a browser upload.
      const boundary = '----daravel-fake-boundary';
      bytes = _fakeMultipart(boundary, form ?? const {}, files);
      requestHeaders.set(
        'content-type',
        'multipart/form-data; boundary=$boundary',
      );
    } else if (json != null) {
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
  int? maxBodyBytes = defaultMaxBodyBytes;

  /// The body limit every request starts with, served or synthetic
  /// (`Request.fake`, the test client), so both paths behave the same:
  /// 50 MiB, the widest limit `BodyLimitsMiddleware` applies. The engine
  /// replaces it with `ServeOptions.maxBodyBytes` (`HTTP_MAX_BODY`), the
  /// middleware and `RouteEntry.bodyLimit` with theirs.
  static const int defaultMaxBodyBytes = 50 << 20;

  /// The request being handled, from anywhere in its zone (Laravel's
  /// `request()`): a helper, an observer, a listener run synchronously.
  /// `null` outside a request (a job, a command, a test without one).
  /// Prefer the handler's `request` parameter where there is one.
  static Request? get current {
    try {
      return Container.current.currentScope?.get<Request>();
    } on StateError {
      return null; // No application at all.
    }
  }

  /// Maximum JSON nesting depth accepted by [body]; `null` means unlimited.
  int? maxJsonDepth;

  Stream<List<int>>? _bodyStream;
  List<int>? _bodyBytes;
  Object? _parsedBody;
  bool _bodyParsed = false;
  final List<UploadedFile> _uploads = [];
  bool _cleanupScheduled = false;
  Map<String, Object?>? _queryInput;
  Map<String, Object?>? _allInput;
  Map<String, Object?>? _transformedQuery;

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

  /// Query parameters as Laravel reads them (PHP's `parse_str`):
  /// `ids[]=1&ids[]=2` is a list, `filter[status]=x` a map, and a repeated
  /// plain key keeps its last value.
  Map<String, Object?> get queryInput =>
      _queryInput ??= parseQueryString(uri.query);

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

  /// The request cookies (Laravel's `$request->cookies->all()`), parsed
  /// like PHP's `$_COOKIE`: URL-decoded, first occurrence wins. Values are
  /// as sent; Laravel's `EncryptCookies` is not applied.
  Map<String, String> get cookies =>
      _cookies ??= Map.unmodifiable(parseRequestCookies(headers));
  Map<String, String>? _cookies;

  /// Replaces the parsed cookies: what a middleware that decrypts them
  /// (`EncryptCookies`) calls, as Laravel's `$request->cookies->set()`.
  void replaceCookies(Map<String, String> cookies) {
    _cookies = Map.unmodifiable(Map<String, String>.of(cookies));
  }

  /// The cookie [name], or [fallback] (Laravel's `$request->cookie()`).
  String? cookie(String name, [String? fallback]) => cookies[name] ?? fallback;

  /// Whether the request carries the cookie [name].
  bool hasCookie(String name) => cookies.containsKey(name);

  /// Host as seen by the client (`X-Forwarded-Host` when trusted).
  String get host => _forwardedHost ?? uri.host;

  /// Scheme, host (with a non-default port) and path, without the query
  /// string or trailing slash (Laravel `$request->url()`), e.g.
  /// `http://localhost/api/users`.
  String get url {
    final forwarded = _forwardedHost;
    final defaultPort = scheme == 'https' ? 443 : 80;
    final authority =
        forwarded ??
        (uri.hasPort && uri.port != defaultPort
            ? '${uri.host}:${uri.port}'
            : uri.host);
    final base = '$scheme://$authority${uri.path}';
    return base.endsWith('/') ? base.replaceAll(RegExp(r'/+$'), '') : base;
  }

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

  /// Lets go of the socket's body: a request upgraded to a WebSocket has
  /// none, and the stream would keep the whole HTTP request (parser,
  /// headers, response) alive as long as the connection.
  void detachBody() {
    _bodyStream = null;
    _bodyBytes ??= const <int>[];
  }

  /// The raw body as it arrives, once, never above [maxBodyBytes]: for
  /// forwarding it ([UpstreamProxy]) or writing it somewhere without
  /// buffering. After [bytes] it replays the cached bytes.
  Stream<List<int>> bodyStream() => _limitedBody();

  /// The body as a stream that never exceeds [maxBodyBytes] (multipart
  /// bodies are parsed as they arrive instead of being buffered).
  Stream<List<int>> _limitedBody() async* {
    final cached = _bodyBytes;
    if (cached != null) {
      _enforceLimit(cached.length);
      yield cached;
      return;
    }
    final declared = contentLength;
    if (declared != null) {
      _enforceLimit(declared);
    }
    final stream = _bodyStream;
    _bodyStream = null;
    _bodyBytes = const <int>[];
    if (stream == null) {
      return;
    }
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      _enforceLimit(total);
      yield chunk;
    }
  }

  /// The uploaded file at [key] (dot notation: `photos.0`), or `null`
  /// (`$request->file('avatar')`).
  Future<UploadedFile?> file(String key) async {
    final value = _dig(await all(), key);
    return value is UploadedFile ? value : null;
  }

  /// Whether [key] holds an uploaded file, or a list with at least one
  /// (`$request->hasFile('photos')`).
  Future<bool> hasFile(String key) async {
    final value = _dig(await all(), key);
    return value is UploadedFile ||
        (value is List && value.any((item) => item is UploadedFile));
  }

  /// Every file uploaded with this request.
  Future<List<UploadedFile>> uploadedFiles() async {
    await body();
    return List.unmodifiable(_uploads);
  }

  /// Deletes the temporary files of the uploads; runs when the request
  /// scope ends (after the response is sent).
  Future<void> deleteUploads() async {
    for (final upload in _uploads) {
      await upload.delete();
    }
  }

  void _scheduleCleanup() {
    if (_cleanupScheduled) {
      return;
    }
    _cleanupScheduled = true;
    Scope? scope;
    try {
      scope = Container.current.currentScope;
    } on StateError {
      scope = null; // No container (a bare kernel in unit tests).
    }
    if (scope != null) {
      scope.onDispose(deleteUploads);
    } else {
      defer(deleteUploads);
    }
  }

  void _enforceLimit(int size) {
    final limit = maxBodyBytes;
    if (limit != null && size > limit) {
      // Laravel's ValidatePostSize message; the limit is not disclosed.
      throw const PayloadTooLargeHttpException();
    }
  }

  /// Parses the body according to its content type:
  /// JSON → decoded value, form → a map read like PHP's `parse_str` (see
  /// [parseQueryString]), otherwise the raw text (or `null` when empty).
  Future<Object?> body() async {
    if (_bodyParsed) {
      return _parsedBody;
    }
    final boundary = multipartBoundary(headers.contentType);
    if (boundary != null) {
      _bodyParsed = true;
      final multipart = await parseMultipart(_limitedBody(), boundary);
      _uploads.addAll(multipart.files);
      if (multipart.files.isNotEmpty) {
        _scheduleCleanup();
      }
      return _parsedBody = multipart.fields;
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
        decoded = jsonDecode(utf8.decode(raw), reviver: _finiteNumbers);
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
      return _parsedBody = parseQueryString(utf8.decode(raw));
    }
    return _parsedBody = utf8.decode(raw);
  }

  /// Registers a transformer applied to every input value returned by
  /// [all] and [input] (strings are visited recursively inside maps/lists).
  void addInputTransformer(InputTransformer transformer) {
    _inputTransformers.add(transformer);
    _allInput = null;
    _transformedQuery = null;
  }

  /// Merged input: query parameters overlaid by body fields (body wins),
  /// with input transformers applied. Computed once per request (until a
  /// transformer is added); each call returns a fresh top-level map.
  Future<Map<String, Object?>> all() async {
    final cached = _allInput;
    if (cached != null) {
      return <String, Object?>{...cached};
    }
    final result = <String, Object?>{...queryInput};
    final parsed = await body();
    if (parsed is Map<String, Object?>) {
      result.addAll(parsed);
    } else if (parsed is Map<Object?, Object?>) {
      parsed.forEach((key, value) => result['$key'] = value);
    }
    final input = _inputTransformers.isEmpty
        ? result
        : _transform(result, '') as Map<String, Object?>;
    _allInput = input;
    return <String, Object?>{...input};
  }

  /// Adds [input] to the body's fields, overwriting those of the same name,
  /// like Laravel's `$request->merge()`: [all], [input] and validation see
  /// it from now on. The body is read first when it was not.
  Future<void> merge(Map<String, Object?> input) async {
    final parsed = await body();
    replace({
      if (parsed is Map<Object?, Object?>)
        for (final MapEntry(:key, :value) in parsed.entries) '$key': value,
      ...input,
    });
  }

  /// Replaces the body's fields with [input], like Laravel's
  /// `$request->replace()`; query parameters stay. A body not read yet is
  /// discarded.
  void replace(Map<String, Object?> input) {
    _parsedBody = <String, Object?>{...input};
    _bodyParsed = true;
    _allInput = null;
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
  ///
  /// Query and form values are strings; for `int`, `double`, `num` and
  /// `bool` they are converted (`?page=5` → `input<int>('page')` is `5`).
  /// A value that cannot be converted yields [fallback].
  Future<T?> input<T>(String key, [T? fallback]) async {
    final value = _dig(await all(), key);
    if (value is T) {
      return value;
    }
    final converted = value is String ? _convert<T>(value) : null;
    return converted ?? fallback;
  }

  /// `$request->integer('page', 1)`: the input as an `int`, or [fallback]
  /// when it is missing or not a number.
  Future<int> integer(String key, [int fallback = 0]) async =>
      _asInt(_dig(await all(), key), fallback);

  /// `$request->float('price')`: the input as a `double`, or [fallback].
  Future<double> float(String key, [double fallback = 0]) async =>
      _asDouble(_dig(await all(), key), fallback);

  /// `$request->boolean('remember')`: `true` for `true`, `1`, `"1"`,
  /// `"true"`, `"on"` and `"yes"` (PHP's `FILTER_VALIDATE_BOOLEAN`), `false`
  /// for anything else, and [fallback] when the key is missing.
  Future<bool> boolean(String key, [bool fallback = false]) async =>
      _asBool(_dig(await all(), key), fallback);

  /// `$request->string('name')`: the input as a `String` (numbers and
  /// booleans are converted), or [fallback] when it is missing.
  Future<String> string(String key, [String fallback = '']) async =>
      _asString(_dig(await all(), key), fallback);

  // Query string, synchronously: it is in memory from the start, so these
  // need no `await` (the body has `request.validated()` for that).

  /// The query parameter [key] (dot notation) as an `int`, without `await`
  /// (`?page=2` → `2`), or [fallback]. Converted like [integer].
  int queryInt(String key, [int fallback = 0]) =>
      _asInt(_dig(_query, key), fallback);

  /// The query parameter [key] as a `double`, or [fallback].
  double queryDouble(String key, [double fallback = 0]) =>
      _asDouble(_dig(_query, key), fallback);

  /// The query parameter [key] as a `bool` (like [boolean]), or [fallback]
  /// when it is missing.
  bool queryBool(String key, [bool fallback = false]) =>
      _asBool(_dig(_query, key), fallback);

  /// The query parameter [key] as a `String`, or [fallback] when it is
  /// missing.
  String queryString(String key, [String fallback = '']) =>
      _asString(_dig(_query, key), fallback);

  /// [queryInput] with the input transformers applied (`TrimStrings`
  /// changes query values too, as in Laravel).
  Map<String, Object?> get _query {
    if (_inputTransformers.isEmpty) {
      return queryInput;
    }
    return _transformedQuery ??=
        _transform(queryInput, '') as Map<String, Object?>;
  }

  static int _asInt(Object? value, int fallback) => switch (value) {
    final int value => value,
    final num value => value.toInt(),
    final String value => _convert<int>(value) ?? fallback,
    _ => fallback,
  };

  static double _asDouble(Object? value, double fallback) => switch (value) {
    final num value => value.toDouble(),
    final String value => _convert<double>(value) ?? fallback,
    _ => fallback,
  };

  static bool _asBool(Object? value, bool fallback) => switch (value) {
    null => fallback,
    final bool value => value,
    final num value => value == 1,
    final String value => _truthy.contains(value.trim().toLowerCase()),
    _ => false,
  };

  static String _asString(Object? value, String fallback) => switch (value) {
    final String value => value,
    final num value => '$value',
    final bool value => value ? '1' : '',
    _ => fallback,
  };

  static const Set<String> _truthy = {'1', 'true', 'on', 'yes'};
  static const Set<String> _falsy = {'0', 'false', 'off', 'no', ''};

  static Type _type<X>() => X;

  static T? _convert<T>(String raw) {
    final value = raw.trim();
    bool wants<X>() => T == X || T == _type<X?>();
    final lower = value.toLowerCase();
    final Object? converted = wants<int>()
        ? int.tryParse(value) ?? double.tryParse(value)?.toInt()
        : wants<double>()
        ? double.tryParse(value)
        : wants<num>()
        ? num.tryParse(value)
        : wants<bool>()
        ? (_truthy.contains(lower)
              ? true
              : (_falsy.contains(lower) ? false : null))
        : null;
    return converted is T ? converted : null;
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

  /// Request attribute holding the result of the route's declared
  /// validation (`.validates()` / `.rules()`).
  static const String validatedAttribute = 'daravel.validated';

  /// The input validated by the route's `.validates(FormRequest)` or
  /// `.rules({...})` (Laravel's `$request->validated()`); throws a
  /// [StateError] when the route declares neither.
  ValidatedData validated() {
    final data = attributes[validatedAttribute];
    if (data is ValidatedData) {
      return data;
    }
    throw StateError(
      'This route declares no validation. Add .validates(FormRequest) or '
      '.rules({...}) to the route, or call request.validate(...).',
    );
  }

  /// Validates the merged input (Laravel `$request->validate()`): throws a
  /// 422 [ValidationException] on failure, otherwise returns only the
  /// validated attributes.
  Future<ValidatedData> validate(
    Map<String, Object> rules, {
    Map<String, String> messages = const <String, String>{},
    Map<String, String> attributes = const <String, String>{},
  }) async {
    Container? container;
    try {
      container = Container.current;
    } on StateError {
      container = null;
    }
    return Validator(
      await all(),
      rules,
      messages: messages,
      attributes: attributes,
      container: container,
      locale: this.attributes['locale'] as String? ?? currentLocale(),
    ).validate();
  }

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

  /// Rejects numbers outside the double range (`1e309` decodes to Infinity):
  /// `numeric` would accept them, and a response or a stored row holding one
  /// could no longer be encoded as JSON (a lasting 500).
  static Object? _finiteNumbers(Object? key, Object? value) {
    if (value is double && !value.isFinite) {
      throw const FormatException('Number out of range');
    }
    return value;
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

/// Parses a query string (or form body) the way PHP's `parse_str` fills
/// Laravel's input: `a[]=1&a[]=2` is a list, `f[status]=x` a map, keys nest
/// up to [maxDepth] levels, and a repeated plain key keeps its last value.
/// Maps whose keys are exactly `0..n-1` become lists, as in Laravel's JSON.
Map<String, Object?> parseQueryString(String query, {int maxDepth = 32}) {
  final pairs = <(String, Object)>[];
  for (final pair in query.split('&')) {
    if (pair.isEmpty) {
      continue;
    }
    final equals = pair.indexOf('=');
    final String key;
    final String value;
    try {
      key = Uri.decodeQueryComponent(
        equals == -1 ? pair : pair.substring(0, equals),
      );
      value = equals == -1
          ? ''
          : Uri.decodeQueryComponent(pair.substring(equals + 1));
    } on ArgumentError {
      continue; // Malformed percent-encoding: PHP drops it too.
    }
    pairs.add((key, value));
  }
  return buildInput(pairs, maxDepth: maxDepth);
}

/// Nests `name[key][]`-style [pairs] into maps and lists, as PHP fills
/// `$_GET`, `$_POST` and `$_FILES` (used for query strings, form bodies and
/// multipart fields and files).
Map<String, Object?> buildInput(
  Iterable<(String, Object)> pairs, {
  int maxDepth = 32,
}) {
  final result = <String, Object?>{};
  for (final (key, value) in pairs) {
    final open = key.indexOf('[');
    final segments = <String>[];
    if (open > 0) {
      var cursor = open;
      while (cursor < key.length && key[cursor] == '[') {
        final close = key.indexOf(']', cursor);
        if (close == -1) {
          break;
        }
        segments.add(key.substring(cursor + 1, close));
        cursor = close + 1;
      }
    }
    if (segments.length > maxDepth) {
      continue;
    }
    _putQueryValue(
      result,
      segments.isEmpty ? key : key.substring(0, open),
      segments,
      value,
    );
  }
  // The top level stays a map even for keys like `0`, `1`.
  return <String, Object?>{
    for (final entry in result.entries) entry.key: _listify(entry.value),
  };
}

void _putQueryValue(
  Map<String, Object?> map,
  String key,
  List<String> segments,
  Object value,
) {
  if (segments.isEmpty) {
    map[key] = value;
    return;
  }
  var child = map[key];
  if (child is! Map<String, Object?>) {
    child = <String, Object?>{};
    map[key] = child;
  }
  var next = segments.first;
  if (next.isEmpty) {
    // `[]` appends at the next integer index, as in PHP.
    var index = 0;
    for (final existing in child.keys) {
      final number = int.tryParse(existing);
      if (number != null && number >= index) {
        index = number + 1;
      }
    }
    next = '$index';
  }
  _putQueryValue(child, next, segments.sublist(1), value);
}

Object? _listify(Object? value) {
  if (value is! Map<String, Object?>) {
    return value;
  }
  final converted = <String, Object?>{
    for (final entry in value.entries) entry.key: _listify(entry.value),
  };
  var index = 0;
  final sequential = converted.keys.every((key) => key == '${index++}');
  if (sequential && converted.isNotEmpty) {
    return converted.values.toList();
  }
  return converted;
}

/// A `multipart/form-data` body with [fields] and [files] (an
/// [UploadedFile] or a list of them per name, sent as `name[]`).
List<int> _fakeMultipart(
  String boundary,
  Map<String, String> fields,
  Map<String, Object> files,
) {
  final out = BytesBuilder();
  void text(String value) => out.add(utf8.encode(value));
  for (final MapEntry(:key, :value) in fields.entries) {
    text('--$boundary\r\n');
    text('Content-Disposition: form-data; name="$key"\r\n\r\n');
    text('$value\r\n');
  }
  for (final MapEntry(:key, :value) in files.entries) {
    final uploads = switch (value) {
      UploadedFile() => [(key, value)],
      List<Object?>() => [
        for (final item in value) ('$key[]', item! as UploadedFile),
      ],
      _ => throw ArgumentError.value(value, key, 'UploadedFile or List'),
    };
    for (final (name, file) in uploads) {
      text('--$boundary\r\n');
      text(
        'Content-Disposition: form-data; name="$name"; '
        'filename="${file.clientName}"\r\n',
      );
      text('Content-Type: ${file.clientMimeType}\r\n\r\n');
      out.add(file.readAsBytesSync());
      text('\r\n');
    }
  }
  text('--$boundary--\r\n');
  return out.takeBytes();
}
