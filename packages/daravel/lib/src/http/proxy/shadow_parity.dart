import 'dart:convert';
import 'dart:math';

import '../../logging/logger.dart';
import '../request.dart';
import '../response.dart';
import 'upstream_proxy.dart';

/// One difference. It holds a path and types, never a value: drifts go to logs
/// and dashboards, and the bodies hold user data.
final class ShadowDrift {
  const ShadowDrift(this.path, this.kind, {this.ours, this.theirs});

  /// Dotted path in the body; empty for the response as a whole.
  final String path;

  /// `status`, `content_type`, `invalid_json`, `missing_key` (the upstream has
  /// it and Daravel does not), `extra_key`, `type` or `length`.
  final String kind;

  /// What Daravel wrote: a status, a media type, a JSON type or a length.
  final Object? ours;

  /// What the upstream wrote.
  final Object? theirs;

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
  JsonStructuralDiffer({Iterable<String> ignoreKeys = const [], this.limit = 5})
    : ignoreKeys = ignoreKeys.toSet();

  /// Paths left out with all below them. `*` stands for a list index:
  /// `data.*.updated_at`.
  final Set<String> ignoreKeys;

  /// Stops after this many: one renamed key in a list of 100 is one finding.
  final int limit;

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

/// A route of Daravel answered differently from the upstream.
final class ShadowParityDrift {
  const ShadowParityDrift({
    required this.method,
    required this.path,
    required this.drifts,
  });

  final String method;
  final String path;
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
  ShadowParityRunner(
    this.proxy, {
    required this.sampleRate,
    this.maxConcurrency = 4,
    Iterable<String> ignoreKeys = const [],
    Iterable<String> except = const [],
    this.logger,
    this.onDrift,
    Random? random,
  }) : differ = JsonStructuralDiffer(ignoreKeys: ignoreKeys),
       except = except.toList(),
       _random = random ?? Random();

  /// The header a replay carries. A request with it is never replayed, so two
  /// applications shadowing each other do not loop.
  static const String header = 'x-daravel-shadow';

  /// Bodies past this are not compared.
  static const int maxBodyBytes = 4 * 1024 * 1024;

  final UpstreamProxy proxy;

  /// The share of requests replayed, from 0 to 1.
  final double sampleRate;

  /// Replays at once per isolate. Past it a sample is dropped, not queued, so
  /// that the upstream never takes more than this from us.
  final int maxConcurrency;

  final JsonStructuralDiffer differ;

  /// Path prefixes that are never replayed.
  final List<String> except;

  final Logger? logger;
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
