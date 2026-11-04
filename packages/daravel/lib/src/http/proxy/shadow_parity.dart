import 'dart:convert';
import 'dart:math';

import '../../logging/logger.dart';
import '../request.dart';
import '../response.dart';
import 'upstream_proxy.dart';

/// One difference. It holds a path and types, never a value: drifts go to logs
/// and dashboards, and the bodies hold user data.
final class ShadowDrift {
  /// A difference of [kind] at [path]; [ours] and [theirs] describe both
  /// sides without their values.
  const ShadowDrift(this.path, this.kind, {this.ours, this.theirs});

  /// Dotted path in the body; empty for the response as a whole.
  final String path;

  /// `status`, `content_type`, `invalid_json`, `missing_key` (the upstream has
  /// it and Daravel does not), `extra_key`, `type` or `length`; with
  /// [ShadowCompare.bytes], also `header` (at the header's name, with the
  /// number of values on each side) and `body` (with both lengths).
  final String kind;

  /// What Daravel wrote: a status, a media type, a JSON type or a length.
  final Object? ours;

  /// What the upstream wrote.
  final Object? theirs;

  /// The drift as JSON, for logs.
  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind,
    'ours': ?ours,
    'theirs': ?theirs,
  };

  @override
  String toString() => '$kind at "$path": $ours vs $theirs';
}

/// Compares the shape of two JSON documents: keys, types and list lengths, not
/// values. Daravel and Laravel read one database, but a shadow request comes
/// later, so a value may rightly have changed.
final class JsonStructuralDiffer {
  /// A differ skipping the [ignoreKeys] paths, stopping after [limit]
  /// differences.
  JsonStructuralDiffer({Iterable<String> ignoreKeys = const [], this.limit = 5})
    : ignoreKeys = ignoreKeys.toSet();

  /// Paths left out with all below them. `*` stands for a list index:
  /// `data.*.updated_at`.
  final Set<String> ignoreKeys;

  /// Stops after this many: one renamed key in a list of 100 is one finding.
  final int limit;

  /// The differences between the JSON values [ours] and [theirs].
  List<ShadowDrift> compare(Object? ours, Object? theirs) {
    final drifts = <ShadowDrift>[];
    _walk(ours, theirs, const [], drifts);
    return drifts;
  }

  bool _ignored(List<String> path) {
    if (ignoreKeys.isEmpty) {
      return false;
    }
    final plain = path.join('.');
    return ignoreKeys.contains(plain) ||
        ignoreKeys.contains(
          [
            for (final segment in path)
              int.tryParse(segment) == null ? segment : '*',
          ].join('.'),
        );
  }

  void _walk(
    Object? ours,
    Object? theirs,
    List<String> path,
    List<ShadowDrift> drifts,
  ) {
    if (drifts.length >= limit || _ignored(path)) {
      return;
    }
    final at = path.join('.');
    final ourType = jsonTypeOf(ours);
    final theirType = jsonTypeOf(theirs);
    if (ourType != theirType) {
      drifts.add(ShadowDrift(at, 'type', ours: ourType, theirs: theirType));
      return;
    }
    if (ours is Map<String, Object?> && theirs is Map<String, Object?>) {
      for (final key in theirs.keys) {
        if (drifts.length >= limit) {
          return;
        }
        final next = [...path, key];
        if (_ignored(next)) {
          continue;
        }
        if (ours.containsKey(key)) {
          _walk(ours[key], theirs[key], next, drifts);
        } else {
          drifts.add(ShadowDrift(next.join('.'), 'missing_key'));
        }
      }
      for (final key in ours.keys) {
        final next = [...path, key];
        if (drifts.length < limit &&
            !theirs.containsKey(key) &&
            !_ignored(next)) {
          drifts.add(ShadowDrift(next.join('.'), 'extra_key'));
        }
      }
    } else if (ours is List<Object?> && theirs is List<Object?>) {
      if (ours.length != theirs.length) {
        drifts.add(
          ShadowDrift(at, 'length', ours: ours.length, theirs: theirs.length),
        );
      }
      for (var i = 0; i < min(ours.length, theirs.length); i++) {
        _walk(ours[i], theirs[i], [...path, '$i'], drifts);
      }
    }
  }
}

/// The JSON type of a decoded value. `int` and `double` stay apart, like `{}`
/// and `[]`: a client can tell them, and PHP's empty array is the classic
/// drift.
String jsonTypeOf(Object? value) => switch (value) {
  null => 'null',
  bool() => 'boolean',
  int() => 'integer',
  double() => 'double',
  String() => 'string',
  List<Object?>() => 'array',
  Map<Object?, Object?>() => 'object',
  _ => 'unknown',
};

/// What a shadow replay compares.
enum ShadowCompare {
  /// The status, the media type and the shape of JSON bodies (keys, types,
  /// list lengths): a value may rightly have changed between the answer and
  /// the replay.
  shape,

  /// The status, the headers and the body byte for byte, for a route whose
  /// answer must not change at all while it moves. Headers that differ by
  /// design are left out ([ShadowParityRunner.ignoreHeaders]), fresh cookie
  /// values are compared by shape ([ShadowParityRunner.freshCookies]), and
  /// [ShadowParityRunner.normalizeKeys] blanks JSON values that differ by
  /// design, at any depth, on both sides.
  bytes,
}

/// A route of Daravel answered differently from the upstream.
final class ShadowParityDrift {
  /// The [drifts] of `method path`.
  const ShadowParityDrift({
    required this.method,
    required this.path,
    required this.drifts,
  });

  /// The request method.
  final String method;

  /// The request path.
  final String path;

  /// The differences found.
  final List<ShadowDrift> drifts;
}

/// Replays a sample of the `GET` and `HEAD` requests Daravel answers to the
/// upstream, and reports where the answers differ, after the client has its
/// response: a route can move to Daravel and be watched against Laravel under
/// real traffic.
///
/// The replay carries the client's cookies and `Authorization`, because most
/// pages need them. A `GET` in the upstream runs for real: it can count a view,
/// and in a shared session it can use up a flash message. Keep such paths out
/// with [except], and start with a small rate.
final class ShadowParityRunner {
  /// Replays a [sampleRate] share of requests through [proxy], at most
  /// [maxConcurrency] at once, skipping [except] paths and the [ignoreKeys]
  /// of bodies.
  ShadowParityRunner(
    this.proxy, {
    required this.sampleRate,
    this.maxConcurrency = 4,
    Iterable<String> ignoreKeys = const [],
    Iterable<String> except = const [],
    this.compare = ShadowCompare.shape,
    Iterable<String> ignoreHeaders = defaultIgnoredHeaders,
    Iterable<String> freshCookies = defaultFreshCookies,
    this.normalizeKeys,
    this.logger,
    this.onDrift,
    Random? random,
  }) : differ = JsonStructuralDiffer(ignoreKeys: ignoreKeys),
       except = except.toList(),
       ignoreHeaders = {for (final name in ignoreHeaders) name.toLowerCase()},
       freshCookies = freshCookies.toSet(),
       _random = random ?? Random();

  /// Headers [ShadowCompare.bytes] leaves out: set per connection or per
  /// answer, by the server rather than the route.
  static const Set<String> defaultIgnoredHeaders = {
    'date',
    'server',
    'connection',
    'keep-alive',
    'transfer-encoding',
    'content-length',
    'x-request-id',
  };

  /// Cookies whose values are new on every answer (Laravel's session and
  /// CSRF cookies): [ShadowCompare.bytes] compares their names and
  /// attributes, not their values.
  static const Set<String> defaultFreshCookies = {
    'laravel_session',
    'XSRF-TOKEN',
  };

  /// What a replay compares.
  final ShadowCompare compare;

  /// Response headers left out of a [ShadowCompare.bytes] comparison
  /// (lower-cased).
  final Set<String> ignoreHeaders;

  /// Cookie names compared by shape only.
  final Set<String> freshCookies;

  /// The JSON keys whose values are blanked on both sides before a
  /// [ShadowCompare.bytes] comparison, per request (for example the client
  /// address a route echoes); empty or null compares the raw bytes.
  final Set<String> Function(Request request)? normalizeKeys;

  /// The header a replay carries. A request with it is never replayed, so two
  /// applications shadowing each other do not loop.
  static const String header = 'x-daravel-shadow';

  /// Bodies past this are not compared.
  static const int maxBodyBytes = 4 * 1024 * 1024;

  /// Forwards the replays to the upstream.
  final UpstreamProxy proxy;

  /// The share of requests replayed, from 0 to 1.
  final double sampleRate;

  /// Replays at once per isolate. Past it a sample is dropped, not queued, so
  /// that the upstream never takes more than this from us.
  final int maxConcurrency;

  /// Compares the bodies.
  final JsonStructuralDiffer differ;

  /// Path prefixes that are never replayed.
  final List<String> except;

  /// Logs drifts as warnings, when given.
  final Logger? logger;

  /// Called with every drift, for metrics such as Pulse's card.
  final void Function(ShadowParityDrift drift)? onDrift;
  final Random _random;

  int _running = 0;

  /// Samples dropped because [maxConcurrency] was reached.
  int dropped = 0;

  /// Replays that got no answer to compare.
  int failed = 0;

  /// Called by the kernel with the answer of a route. Decides here and costs
  /// the client nothing: the replay runs after the response is sent.
  void observe(Request request, Response response) {
    if (sampleRate <= 0 ||
        (request.method != 'GET' && request.method != 'HEAD') ||
        request.headers.first(header) != null ||
        response.headers.first('content-encoding') != null ||
        except.any(request.path.startsWith) ||
        _random.nextDouble() >= sampleRate) {
      return;
    }
    final body = response.body;
    if (body is! BytesBody || body.bytes.length > maxBodyBytes) {
      return;
    }
    request.defer(() => _replay(request, response, body.bytes));
  }

  Future<void> _replay(
    Request request,
    Response response,
    List<int> bytes,
  ) async {
    if (_running >= maxConcurrency) {
      dropped++;
      return;
    }
    _running++;
    try {
      final answer = await proxy.shadow(request, maxBytes: maxBodyBytes);
      if (answer == null) {
        failed++;
        return;
      }
      final drifts = _compare(request, response, bytes, answer);
      if (drifts.isEmpty) {
        return;
      }
      logger?.warning('Shadow parity drift', {
        'method': request.method,
        'path': request.path,
        'drifts': [for (final drift in drifts) drift.toJson()],
      });
      onDrift?.call(
        ShadowParityDrift(
          method: request.method,
          path: request.path,
          drifts: drifts,
        ),
      );
    } finally {
      _running--;
    }
  }

  List<ShadowDrift> _compare(
    Request request,
    Response response,
    List<int> bytes,
    ShadowAnswer answer,
  ) {
    if (compare == ShadowCompare.bytes) {
      return compareBytes(request, response, bytes, answer);
    }
    final drifts = <ShadowDrift>[
      if (response.status != answer.status)
        ShadowDrift('', 'status', ours: response.status, theirs: answer.status),
    ];
    final ours = _mediaType(response.headers.first('content-type'));
    final theirs = _mediaType(answer.contentType);
    if (ours != theirs) {
      return [
        ...drifts,
        ShadowDrift('', 'content_type', ours: ours, theirs: theirs),
      ];
    }
    if (request.method == 'HEAD' || !_isJson(ours)) {
      return drifts;
    }
    final ourBody = _decode(bytes);
    final theirBody = _decode(answer.body);
    if (ourBody == _invalid || theirBody == _invalid) {
      return [
        ...drifts,
        ShadowDrift(
          '',
          'invalid_json',
          ours: ourBody == _invalid ? 'invalid' : 'json',
          theirs: theirBody == _invalid ? 'invalid' : 'json',
        ),
      ];
    }
    return [...drifts, ...differ.compare(ourBody, theirBody)];
  }

  /// The [ShadowCompare.bytes] differences between Daravel's [response]
  /// (whose body is [bytes]) and the upstream's [answer] to [request].
  List<ShadowDrift> compareBytes(
    Request request,
    Response response,
    List<int> bytes,
    ShadowAnswer answer,
  ) {
    final drifts = <ShadowDrift>[
      if (response.status != answer.status)
        ShadowDrift('', 'status', ours: response.status, theirs: answer.status),
    ];
    final ours = <String, List<String>>{
      for (final MapEntry(:key, :value) in response.headers.entries)
        key.toLowerCase(): value,
    };
    final names = {...ours.keys, ...answer.headers.keys}
      ..removeAll(ignoreHeaders);
    for (final name in names.toList()..sort()) {
      var a = ours[name] ?? const <String>[];
      var b = answer.headers[name] ?? const <String>[];
      if (name == 'set-cookie') {
        a = [for (final cookie in a) _cookieShape(cookie)];
        b = [for (final cookie in b) _cookieShape(cookie)];
      }
      if (a.join('\n') != b.join('\n')) {
        drifts.add(
          ShadowDrift(name, 'header', ours: a.length, theirs: b.length),
        );
      }
    }
    if (request.method == 'HEAD') {
      return drifts;
    }
    final keys = normalizeKeys?.call(request) ?? const <String>{};
    final ourBody = _normalized(bytes, keys);
    final theirBody = _normalized(answer.body, keys);
    if (!_sameBytes(ourBody, theirBody)) {
      drifts.add(
        ShadowDrift('', 'body', ours: ourBody.length, theirs: theirBody.length),
      );
    }
    return drifts;
  }

  /// A `Set-Cookie` value with a fresh cookie's value and expiry blanked.
  String _cookieShape(String setCookie) {
    final eq = setCookie.indexOf('=');
    if (eq < 0 || !freshCookies.contains(setCookie.substring(0, eq).trim())) {
      return setCookie;
    }
    final semi = setCookie.indexOf(';');
    final attributes = semi < 0 ? '' : setCookie.substring(semi);
    return '${setCookie.substring(0, eq)}=<fresh>'
        '${attributes.replaceAll(RegExp('expires=[^;]*', caseSensitive: false), 'expires=<date>')}';
  }

  static List<int> _normalized(List<int> body, Set<String> keys) {
    if (keys.isEmpty) {
      return body;
    }
    final decoded = _decode(body);
    if (decoded == _invalid) {
      return body;
    }
    return utf8.encode(jsonEncode(_blank(decoded, keys)));
  }

  static Object? _blank(Object? value, Set<String> keys) => switch (value) {
    final Map<String, Object?> map => {
      for (final MapEntry(:key, value: inner) in map.entries)
        key: keys.contains(key) ? '<normalized>' : _blank(inner, keys),
    },
    final List<Object?> list => [for (final item in list) _blank(item, keys)],
    _ => value,
  };

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  static String? _mediaType(String? value) =>
      value?.split(';').first.trim().toLowerCase();

  static bool _isJson(String? mediaType) =>
      mediaType != null &&
      (mediaType == 'application/json' || mediaType.endsWith('+json'));

  static const Object _invalid = Object();

  static Object? _decode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return _invalid;
    }
  }
}
