import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import '../foundation/slashes.dart';
import '../foundation/container.dart';
import '../foundation/env.dart';
import '../foundation/ids.dart';
import '../foundation/locale.dart';
import '../routing/domain_pattern.dart';
import '../routing/route_entry.dart';
import '../validation/validated_data.dart';
import '../validation/validator.dart';
import 'cookies.dart';
import 'csp.dart';
import 'headers.dart';
import 'host_header.dart';
import 'http_exceptions.dart';
import 'json_nesting.dart';
import 'multipart.dart';
import 'uploaded_file.dart';

/// Rewrites an input value; used by `TrimStrings` and
/// `ConvertEmptyStringsToNull` style middleware.
///
/// [key] is the value's path in dot notation (`user.password`, `tags.0`),
/// as Laravel's `TransformsRequest::cleanArray` passes it.
typedef InputTransformer = Object? Function(String key, Object? value);

/// Incoming HTTP request (BLUEPRINT_V2 §7.2.2).
///
/// Instances are created by the server engine from `dart:io` requests or by
/// [Request.fake] in tests. The body is read lazily, at most once, and never
/// beyond [maxBodyBytes].
final class Request {
  Request._({
    required String method,
    required this.uri,
    required this.headers,
    required this.remoteAddress,
    required this.id,
    this._bodyStream,
    this._bodyBytes,
  }) : _method = method,
       originalMethod = method;

  /// Wraps a `dart:io` request.
  ///
  /// [uri] comes from the request line, the `Host` header and the listener
  /// ([secure]: whether it is TLS; [listenerAuthority]: its address, for a
  /// request without `Host`), never from `X-Forwarded-*` headers, which
  /// any client can send: only `TrustProxiesMiddleware` applies them, for a
  /// trusted peer. `HttpRequest.requestedUri` is not used, because it reads
  /// `X-Forwarded-Proto` and `X-Forwarded-Host` from whoever sent them.
  ///
  /// Throws [BadRequestHttpException] for a request `dart:io` accepted but
  /// that cannot be represented: a `Host` (or absolute-form authority) that
  /// is not `uri-host [":" port]`, which could otherwise change the path or
  /// host the application sees (`/`, `?`, `#`, `@`, a backslash, spaces;
  /// see `parseHostAuthority`), userinfo in an absolute-form target, or a
  /// header value [Headers] refuses (control characters). The path and
  /// query always come from the request line. (Of several `Host` headers `dart:io` keeps the
  /// last; RFC 9112 §3.2 asks for 400, which it does not give.) The
  /// engine answers 400; without this the error would escape the server's
  /// listen callback and take the serving isolate down.
  factory Request.fromHttpRequest(
    HttpRequest httpRequest, {
    required String id,
    bool secure = false,
    String listenerAuthority = 'localhost',
  }) {
    final Uri uri;
    final Headers headers;
    try {
      uri = _requestUri(
        httpRequest.uri,
        httpRequest.headers[HttpHeaders.hostHeader],
        secure: secure,
        listenerAuthority: listenerAuthority,
      );
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
    final requestHeaders = Headers(headers);
    // The socket path takes the host from this header too.
    final hostHeader = requestHeaders.first('host');
    if (hostHeader != null) {
      // `[::1]:8080`: the colons of an IPv6 address are not a port.
      final bracket = hostHeader.lastIndexOf(']');
      final colon = hostHeader.indexOf(':', bracket + 1);
      uri = colon == -1
          ? uri.replace(host: hostHeader)
          : uri.replace(
              host: hostHeader.substring(0, colon),
              port: int.tryParse(hostHeader.substring(colon + 1)),
            );
    }
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(
        queryParameters: <String, String>{...uri.queryParameters, ...query},
      );
    }
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

  /// Upper-cased HTTP method, after a `_method` override.
  String get method => _method;
  String _method;

  /// The method on the wire (Laravel's `getRealMethod`).
  final String originalMethod;

  /// Used by [MethodOverrideMiddleware].
  void overrideMethod(String method) => _method = method.toUpperCase();

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

  /// This request's Content-Security-Policy nonce: 16 bytes from a CSPRNG,
  /// base64, made on first read and the same for the rest of the request.
  /// Put it on inline scripts and styles (`<script nonce="...">`); a
  /// `SecurityHeadersMiddleware` policy that lists `Csp.nonce` sends it as
  /// `'nonce-...'`, so those run without `'unsafe-inline'`. Each request has
  /// its own, so a nonce seen in one page is no use to an injected script in
  /// another.
  String get cspNonce => _cspNonce ??= Csp.generateNonce();

  /// Whether [cspNonce] has been made for this request.
  bool get hasCspNonce => _cspNonce != null;

  String? _cspNonce;

  /// The limits a multipart body is read with ([body], [file], [all]):
  /// the defaults, until the kernel sets the application's
  /// (`HTTP_MULTIPART_*`, [MultipartLimits.fromEnv]) on every request,
  /// served or from the test client.
  MultipartLimits multipartLimits = const MultipartLimits();

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

  /// The deepest nesting [body] accepts with a `400` (Bad Request), set by
  /// `BodyLimitsMiddleware` (`jsonDepth`, 64); `null` (the default) means
  /// this check is off and only [jsonMaxDepth] applies.
  int? maxJsonDepth;

  /// The JSON depth of the body, with the meaning of PHP's `json_decode`
  /// `$depth` (Laravel's `Request::json()` uses its default, 512): a body
  /// whose arrays and objects nest [jsonMaxDepth] deep **or deeper** is
  /// read as no input at all, as Laravel reads it, not refused. With 512,
  /// `{"a":[[…1…]]}` holding 510 arrays (511 levels) is read, and one more
  /// array (512 levels) gives empty input, so `required` fails with a 422.
  /// This is PHP's count, checked against Laravel 13.40; it is not off by
  /// one.
  ///
  /// The nesting is counted on the bytes before they are decoded, in one
  /// pass without recursion. A body past it never reaches code that walks
  /// the input recursively: measured on Dart 3.13 with the limit off,
  /// `distinct` over `a.*` overflowed the stack (a 500) from 2 345 nested
  /// levels and a response echoing the input from 3 433, so `dartisan
  /// doctor` warns in production above 1 024. Counting costs about 1 ms
  /// per MiB (AOT), a tenth of decoding a typical body; a body shorter
  /// than the limit, which cannot nest that deep, and a request with no
  /// limit are not counted.
  ///
  /// The default, [defaultJsonMaxDepth], applies to every request, served
  /// or synthetic; the kernel sets the application's (`HTTP_JSON_MAX_DEPTH`,
  /// [jsonMaxDepthFromEnv]) on each one. `null` turns it off. Form and
  /// multipart bodies are not affected.
  int? jsonMaxDepth = defaultJsonMaxDepth;

  /// PHP's `json_decode` default depth, which Laravel reads request bodies
  /// with: 512 (511 nested levels are read, 512 are not).
  static const int defaultJsonMaxDepth = 512;

  /// [jsonMaxDepth] from `HTTP_JSON_MAX_DEPTH`: unset means
  /// [defaultJsonMaxDepth], `0` no limit; a negative value is an error at
  /// boot.
  static int? jsonMaxDepthFromEnv(Env env) {
    final value = env.integer('HTTP_JSON_MAX_DEPTH', defaultJsonMaxDepth);
    if (value < 0) {
      throw ArgumentError.value(
        value,
        'HTTP_JSON_MAX_DEPTH',
        'must be a positive depth, or 0 for no limit',
      );
    }
    return value == 0 ? null : value;
  }

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
  int? _forwardedPort;
  bool _fromTrustedProxy = false;

  final List<InputTransformer> _inputTransformers = <InputTransformer>[];

  /// How many of [_inputTransformers] the body's fields have been through
  /// already. 0 for the body as the client sent it. [merge] and [replace]
  /// set it to the count at that moment: Laravel transforms its parameter
  /// bags when the middleware runs, so input merged afterwards is kept as
  /// given, and only a transformer registered later still sees it.
  int _bodyTransformedBy = 0;
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

  /// Host as seen by the client, without a port (`X-Forwarded-Host` when
  /// trusted; Symfony's `getHost()`). An IPv6 address comes without its
  /// brackets.
  String get host => _forwardedHost ?? uri.host;

  /// Port as seen by the client (Symfony's `getPort()`): from a trusted
  /// proxy's `X-Forwarded-Port`, else the port of its `X-Forwarded-Host`,
  /// else the port of the request's `Host`, else the default of [scheme]
  /// (443 for `https`, 80 otherwise).
  int get port {
    if (_forwardedPort case final int forwarded) {
      return forwarded;
    }
    // A forwarded host without a port says nothing about the Host's.
    if (_forwardedHost == null && uri.hasPort) {
      return uri.port;
    }
    return scheme == 'https' ? 443 : 80;
  }

  /// The host a signed URL of this route covers: the route's own, and
  /// none for a route that answers on any host.
  String? get signedHost =>
      route?.domainPattern == null ? null : DomainPattern.normalize(host);

  /// Scheme, host (with a non-default port) and path, without the query
  /// string or trailing slash (Laravel `$request->url()`), e.g.
  /// `http://localhost/api/users`.
  String get url {
    final defaultPort = scheme == 'https' ? 443 : 80;
    final name = host.contains(':') ? '[$host]' : host;
    final authority = port == defaultPort ? name : '$name:$port';
    final base = '$scheme://$authority${uri.path}';
    return trimTrailingSlashes(base);
  }

  /// Whether a trusted proxy's forwarding headers were applied to this
  /// request (`TrustProxiesMiddleware`; Laravel's `isFromTrustedProxy()`).
  /// Without it [scheme], [host] and [url] come from the request line,
  /// the `Host` header and the listener only.
  bool get isFromTrustedProxy => _fromTrustedProxy;

  /// Records forwarding information. Called by `TrustProxiesMiddleware`.
  /// [host] is a host without a port; [port] the forwarded port (from
  /// `X-Forwarded-Port`, else the port `X-Forwarded-Host` carried).
  void applyForwarded({
    String? ip,
    List<String>? ips,
    String? scheme,
    String? host,
    int? port,
  }) {
    _fromTrustedProxy = true;
    if (port != null) {
      _forwardedPort = port;
    }
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
    if (accept.contains('/json') || accept.contains('+json')) {
      return true;
    }
    // Laravel's `ajax() && acceptsAnyContentType()`: an Inertia visit is an
    // XHR that asks for HTML.
    final first = accept.split(',').first.split(';').first.trim();
    return headers.first('x-requested-with') == 'XMLHttpRequest' &&
        (first.isEmpty || first == '*/*' || first == '*');
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
      _cacheHandedOut = true;
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
    await for (final chunk in _guarded(stream)) {
      builder.add(chunk);
    }
    return _bodyBytes = builder.takeBytes();
  }

  /// [source] limited to [maxBodyBytes] as it arrives. Going over it is a
  /// [PayloadTooLargeHttpException], and the rest of the body is left to
  /// the server ([bodyRefusedWhileReading]) instead of cancelled: on a
  /// socket, cancelling it closed the connection before the `413` was
  /// written, so the client got no response at all.
  Stream<List<int>> _guarded(Stream<List<int>> source) {
    late final StreamSubscription<List<int>> subscription;
    var refused = false;
    var total = 0;
    final controller = StreamController<List<int>>(sync: true);
    void refuse(Object error) {
      if (refused) {
        return;
      }
      refused = true;
      _abortRead = null;
      _refuseRest(subscription);
      controller
        ..addError(error)
        ..close();
    }

    controller
      ..onListen = () {
        _abortRead = refuse;
        subscription = source.listen(
          (chunk) {
            total += chunk.length;
            _streamedBytes += chunk.length;
            final limit = maxBodyBytes;
            if (limit != null && total > limit) {
              refuse(const PayloadTooLargeHttpException());
              return;
            }
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            _abortRead = null;
            unawaited(controller.close());
          },
        );
      }
      ..onPause = (() => subscription.pause())
      ..onResume = (() => subscription.resume())
      ..onCancel = () => refused ? null : subscription.cancel();
    return controller.stream;
  }

  /// Stops the read of the body under way with [error], as going over
  /// [maxBodyBytes] does: what reads it (the body parser) fails, and the
  /// rest is left to the server ([bodyRefusedWhileReading]). Used when the
  /// read takes too long. Nothing happens when no read is under way.
  void abortBodyRead(Object error) => _abortRead?.call(error);

  void Function(Object error)? _abortRead;

  int _streamedBytes = 0;
  bool _cacheHandedOut = false;

  /// How many bytes of the body have been read so far, by anything.
  int get bodyBytesRead =>
      _cacheHandedOut ? (_bodyBytes?.length ?? 0) : _streamedBytes;

  /// Throws [PayloadTooLargeHttpException] when more of the body than
  /// [maxBodyBytes] was already read: a limit set after something read the
  /// body early (a route's `bodyLimit`, applied after the global
  /// middleware, which may have parsed a form to find `_method`).
  void enforceLimitOnBodyRead() => _enforceLimit(bodyBytesRead);

  /// At most this much of a body refused while reading is thrown away
  /// before the response; then the body is paused (the client waits) until
  /// the server answers and closes the connection.
  static const int refusedBodyDiscardBytes = 256 * 1024;

  StreamSubscription<List<int>>? _refusedBody;

  void _refuseRest(StreamSubscription<List<int>> subscription) {
    var discarded = 0;
    subscription.onData((chunk) {
      discarded += chunk.length;
      if (discarded >= refusedBodyDiscardBytes && !subscription.isPaused) {
        subscription.pause();
      }
    });
    _refusedBody = subscription;
  }

  /// Whether the body went over [maxBodyBytes] while it was read (a
  /// chunked body, or one longer than it declared): the rest is still on
  /// the connection, so the server answers and then closes it.
  bool get bodyRefusedWhileReading => _refusedBody != null;

  /// Cancels the body [bodyRefusedWhileReading] kept, which ends the
  /// connection: only once the response has been written and flushed (a
  /// streamed one). A socket detached to answer reads the rest off itself.
  Future<void> releaseRefusedBody() async {
    final subscription = _refusedBody;
    _refusedBody = null;
    await subscription?.cancel();
  }

  /// Lets go of the socket's body: a request upgraded to a WebSocket has
  /// none, and the stream would keep the whole HTTP request (parser,
  /// headers, response) alive as long as the connection.
  void detachBody() {
    _bodyStream = null;
    _bodyBytes ??= const <int>[];
  }

  /// Whether the body is still on the socket, unread and unclaimed:
  /// nothing called [bytes], [body] or [bodyStream] for it, or the call was
  /// refused before reading (a declared `Content-Length` above
  /// [maxBodyBytes]). The server takes such a body off the connection
  /// itself before it answers, so the response never waits for a client
  /// that sends it slowly. Always false for [Request.fake].
  bool get hasUnreadBody => _bodyStream != null;

  /// The raw body as it arrives, once, never above [maxBodyBytes]: for
  /// forwarding it ([UpstreamProxy]) or writing it somewhere without
  /// buffering. After [bytes] it replays the cached bytes.
  ///
  /// The call claims the body (see [hasUnreadBody]) even before the
  /// stream is listened to.
  Stream<List<int>> bodyStream() => _limitedBody();

  /// The body as a stream that never exceeds [maxBodyBytes] (multipart
  /// bodies are parsed as they arrive instead of being buffered).
  Stream<List<int>> _limitedBody() {
    final cached = _bodyBytes;
    final stream = _bodyStream;
    if (cached == null) {
      _bodyStream = null;
      _bodyBytes = const <int>[];
    }
    return _limited(cached, stream);
  }

  Stream<List<int>> _limited(
    List<int>? cached,
    Stream<List<int>>? stream,
  ) async* {
    if (cached != null) {
      _enforceLimit(cached.length);
      _cacheHandedOut = true;
      yield cached;
      return;
    }
    final declared = contentLength;
    if (declared != null) {
      try {
        _enforceLimit(declared);
      } on PayloadTooLargeHttpException {
        // Refused unread: it stays the server's to discard.
        _bodyStream ??= stream;
        rethrow;
      }
    }
    if (stream == null) {
      return;
    }
    yield* _guarded(stream);
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
      final multipart = await parseMultipart(
        _limitedBody(),
        boundary,
        limits: multipartLimits,
      );
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
      final refuseAbove = maxJsonDepth;
      final emptyFrom = jsonMaxDepth;
      // The nesting at which a limit applies; each level takes a byte, so
      // a body shorter than the lowest of them is not counted at all.
      final refuseAt = refuseAbove == null ? null : refuseAbove + 1;
      final lowest = [
        ?refuseAt,
        ?emptyFrom,
      ].fold<int?>(null, (low, at) => low == null ? at : math.min(low, at));
      if (lowest != null && raw.length >= lowest) {
        // Counted on the bytes, before decoding: nothing that walks the
        // decoded value recursively ever sees a nesting past the limits.
        final nesting = jsonNesting(
          raw,
          stopAt: math.max(refuseAt ?? 0, emptyFrom ?? 0),
        );
        if (refuseAbove != null && nesting > refuseAbove) {
          throw BadRequestHttpException(
            'JSON body nesting exceeds the limit of $refuseAbove levels.',
          );
        }
        if (emptyFrom != null && nesting >= emptyFrom) {
          // PHP's json_decode gives null past its depth, and Laravel's
          // `(array) null` is no input at all.
          return _parsedBody = <String, Object?>{};
        }
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(raw), reviver: _finiteNumbers);
      } on FormatException catch (error) {
        throw BadRequestHttpException('Malformed JSON body: ${error.message}');
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

  /// Merged input: the body fields, then the query parameters the body does
  /// not have (Laravel's `input + query`: the body wins key by key, and its
  /// keys come first), with input transformers applied. Computed once per
  /// request (until a transformer is added); each call returns a fresh
  /// top-level map.
  ///
  /// Transformers apply to the input as the client sent it, like Laravel's
  /// `TransformsRequest`, which rewrites the request's parameter bags when
  /// the middleware runs. Fields set later by [merge] or [replace] are kept
  /// as given.
  Future<Map<String, Object?>> all() async {
    final cached = _allInput;
    if (cached != null) {
      return <String, Object?>{...cached};
    }
    final body = await bodyInput();
    final input = <String, Object?>{
      ...body,
      for (final MapEntry(:key, :value) in _query.entries)
        if (!body.containsKey(key)) key: value,
    };
    _allInput = input;
    return <String, Object?>{...input};
  }

  /// The body's fields as [all] sees them, without the query (Laravel's
  /// `getInputSource()->all()`): the transformers the fields have not been
  /// through yet applied, so a body sent by the client gets all of them and
  /// a [replace]d one only those registered since. A middleware that
  /// rebuilds the body with [replace] starts from this, so the fields the
  /// client sent keep what `TrimStrings` made of them.
  ///
  /// A JSON body that is a list at the top (`[{"email": ...}, ...]`, a bulk
  /// import) gives its elements under the keys `'0'`, `'1'`, ..., as PHP
  /// reads a list: `input('0.email')` and a rule on `*.email` reach them,
  /// and next to the query the body wins key by key, as Laravel's
  /// `input + query` does.
  Future<Map<String, Object?>> bodyInput() async {
    final parsed = await body();
    final fields = <String, Object?>{
      if (parsed is Map<Object?, Object?>)
        for (final MapEntry(:key, :value) in parsed.entries) '$key': value
      else if (parsed is List<Object?>)
        for (final (index, value) in parsed.indexed) '$index': value,
    };
    if (_bodyTransformedBy >= _inputTransformers.length) {
      return fields;
    }
    return _transform(fields, '', _bodyTransformedBy) as Map<String, Object?>;
  }

  /// Adds [input] to the body's fields, overwriting those of the same name,
  /// like Laravel's `$request->merge()`: [all], [input] and validation see
  /// it from now on. The body is read first when it was not.
  ///
  /// The fields already there keep what the input transformers made of
  /// them, and [input] is kept as given (Laravel merges into a parameter
  /// bag that `TrimStrings` and `ConvertEmptyStringsToNull` cleaned
  /// earlier).
  Future<void> merge(Map<String, Object?> input) async {
    _setBody({...await bodyInput(), ...input});
  }

  /// Replaces the body's fields with [input], like Laravel's
  /// `$request->replace()`; query parameters stay. A body not read yet is
  /// discarded. [input] is kept as given: the input transformers registered
  /// so far do not apply to it.
  void replace(Map<String, Object?> input) => _setBody({...input});

  void _setBody(Map<String, Object?> fields) {
    _parsedBody = fields;
    _bodyParsed = true;
    _bodyTransformedBy = _inputTransformers.length;
    _allInput = null;
  }

  /// Runs the transformers from index [from] on every leaf of [value]. The
  /// key is the leaf's path in dot notation (`user.password`, `tags.0`), as
  /// `TransformsRequest::cleanArray` builds it.
  Object? _transform(Object? value, String key, [int from = 0]) {
    String path(Object? child) => key.isEmpty ? '$child' : '$key.$child';
    if (value is Map<Object?, Object?>) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': _transform(entry.value, path(entry.key), from),
      };
    }
    if (value is List<Object?>) {
      return <Object?>[
        for (var i = 0; i < value.length; i++)
          _transform(value[i], path(i), from),
      ];
    }
    var current = value;
    for (var i = from; i < _inputTransformers.length; i++) {
      current = _inputTransformers[i](key, current);
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

  bool get _mayHaveBody =>
      !const {'GET', 'HEAD', 'OPTIONS'}.contains(method) &&
      (int.tryParse(headers.first('content-length') ?? '') ?? 0) > 0;

  /// [input] for code that cannot wait, such as a model scope. It sees the
  /// body only once something awaited the input of this request (a
  /// validation, a filter, [all]); until then the query string.
  ///
  /// With asserts on (tests, `dart run --enable-asserts`) a key the query
  /// lacks on a request whose body was not read yet fails loudly, because
  /// the body would be skipped without a word.
  T? inputSync<T>(String key, [T? fallback]) {
    final value = _dig(_allInput ?? queryInput, key);
    assert(
      _allInput != null || value != null || !_mayHaveBody,
      'Request.inputSync("$key") ran before the body was read: await '
      'request.all() or validate() first.',
    );
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
  ///
  /// Typed ids (opt-in): an extension type over `int` or `String`
  /// (`param<UserId>('user')`) works as its representation. To validate
  /// further, pass [parse] (`parse: UserId.parse`), or register a parser
  /// for the parameter name in `bootstrap/ids.dart` (`IdParsers`, see
  /// `ApplicationBuilder.withIds`); every read of that name then goes
  /// through it. A [FormatException] or [ArgumentError] from a parser
  /// yields a 404.
  T param<T>(String key, {T Function(String raw)? parse}) {
    final raw = _routeParams[key];
    if (raw == null) {
      throw NotFoundHttpException('Route parameter [$key] is missing.');
    }
    final Object? Function(String raw)? parser =
        parse ?? Container.currentOrNull?.tryMake<IdParsers>()?.parserFor(key);
    if (parser != null) {
      final Object? parsed;
      try {
        parsed = parser(raw);
      } on FormatException {
        throw NotFoundHttpException(
          'Route parameter [$key] with value "$raw" is not a valid id.',
        );
      } on ArgumentError {
        throw NotFoundHttpException(
          'Route parameter [$key] with value "$raw" is not a valid id.',
        );
      }
      if (parsed is T) {
        return parsed;
      }
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
  // The next `[]` index of every map built here (PHP's nNextFreeElement):
  // finding it by scanning the map's keys made `a[]=` pairs quadratic.
  final nextIndex = HashMap<Map<String, Object?>, int>.identity();
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
      nextIndex,
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
  Map<Map<String, Object?>, int> nextIndex,
) {
  if (segments.isEmpty) {
    _noteKey(map, key, nextIndex);
    map[key] = value;
    return;
  }
  var child = map[key];
  if (child is! Map<String, Object?>) {
    child = <String, Object?>{};
    _noteKey(map, key, nextIndex);
    map[key] = child;
  }
  var next = segments.first;
  if (next.isEmpty) {
    // `[]` appends at the next integer index, as in PHP: one past the
    // highest integer key so far.
    next = '${nextIndex[child] ?? 0}';
  }
  _putQueryValue(child, next, segments.sublist(1), value, nextIndex);
}

/// Keeps the next `[]` index of [map] one past its highest integer key.
void _noteKey(
  Map<String, Object?> map,
  String key,
  Map<Map<String, Object?>, int> nextIndex,
) {
  final number = int.tryParse(key);
  if (number != null && number >= (nextIndex[map] ?? 0)) {
    nextIndex[map] = number + 1;
  }
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

/// The URI of a request read off a socket, built from parts, never by
/// joining strings a client sent:
///
/// - the scheme of the listener ([secure]); the scheme an absolute-form
///   target writes is not taken (a client can write `https://` on a plain
///   listener);
/// - the authority of the request line's target when it is in absolute
///   form (RFC 9112 §3.2.2: the `Host` header is then ignored), else of the
///   `Host` header ([hosts]), else [listenerAuthority] (HTTP/1.0). It must
///   be `uri-host [":" port]` ([parseHostAuthority]); anything else, and
///   userinfo in an absolute-form target, throws [FormatException];
/// - the path and query of the target, as written.
Uri _requestUri(
  Uri target,
  List<String>? hosts, {
  required bool secure,
  required String listenerAuthority,
}) {
  final scheme = secure ? 'https' : 'http';
  final HostAuthority? authority;
  final String raw;
  if (target.hasScheme) {
    if (target.userInfo.isNotEmpty) {
      throw const FormatException('Userinfo in the request target.');
    }
    authority = parseHostAuthority(
      target.hasPort ? target.authority : _bracketed(target.host),
    );
    raw = _pathAndQuery(target);
  } else {
    authority = parseHostAuthority(
      hosts == null || hosts.isEmpty ? listenerAuthority : hosts.first,
    );
    // `//x/y` is a path here, though Uri.parse reads `x` as an authority.
    raw = target.toString();
  }
  if (authority == null) {
    throw const FormatException('Malformed Host.');
  }
  final hash = raw.indexOf('#');
  final end = hash < 0 ? raw.length : hash;
  final found = raw.indexOf('?');
  final mark = found < 0 || found > end ? -1 : found;
  final query = mark < 0 ? null : raw.substring(mark + 1, end);
  final uri = Uri(
    scheme: scheme,
    host: authority.host,
    port: authority.port,
    path: raw.substring(0, mark < 0 ? end : mark),
    query: query == null || query.isEmpty ? null : query,
  );
  // `Uri` built from parts drops an empty query; the request line kept it
  // (`/p?`). Appended to a URI already built, it changes nothing else.
  return query != null && query.isEmpty ? Uri.parse('$uri?') : uri;
}

/// [host] as an authority writes it: an IPv6 address in brackets.
String _bracketed(String host) => host.contains(':') ? '[$host]' : host;

/// The path and query of an absolute-form [target], as written.
String _pathAndQuery(Uri target) =>
    '${target.path.isEmpty ? '/' : target.path}'
    '${target.hasQuery ? '?${target.query}' : ''}';
