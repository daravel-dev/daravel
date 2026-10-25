import 'dart:io';

import 'package:crypto/crypto.dart';

import '../headers.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Laravel's `cache.headers` middleware (`SetCacheHeaders`):
///
/// ```dart
/// router.get('/catalog', catalog).middleware(const [
///   'cache.headers:public;max_age=3600;etag',
/// ]);
/// ```
///
/// On successful `GET`/`HEAD` responses with a body it sets `Cache-Control`
/// from the options (`public`, `private`, `max_age`, `s_maxage`,
/// `must_revalidate`, `no_cache`, `no_store`, `no_transform`,
/// `proxy_revalidate`, `immutable`, `stale_while_revalidate`,
/// `stale_if_error`), `ETag` (`etag`: a hash of the body) and
/// `Last-Modified` (`last_modified`: a Unix timestamp or a date), and
/// answers `304 Not Modified` when `If-None-Match` (or, without it,
/// `If-Modified-Since`) shows the client's copy is current. Headers are
/// written as Symfony writes them for Laravel: directives sorted, `private`
/// added when neither `public`, `private` nor `s-maxage` is given.
final class CacheHeadersMiddleware implements Middleware {
  const CacheHeadersMiddleware(this.options);

  /// `cache.headers:public;max_age=3600;etag` (the alias' parameter).
  factory CacheHeadersMiddleware.fromParams(List<String> params) =>
      CacheHeadersMiddleware(parseOptions(params.join(',')));

  /// Option name → value (`null` for flags such as `public` or `etag`).
  final Map<String, String?> options;

  /// Laravel's `parseOptions`: `public;max_age=3600;etag`.
  static Map<String, String?> parseOptions(String options) {
    final trimmed = options.endsWith(';')
        ? options.substring(0, options.length - 1)
        : options;
    return {
      for (final option in trimmed.split(';'))
        if (option.isNotEmpty)
          option.split('=').first: option.contains('=')
              ? option.substring(option.indexOf('=') + 1)
              : null,
    };
  }

  static const Map<String, String> _directives = {
    'max_age': 'max-age',
    's_maxage': 's-maxage',
    'stale_while_revalidate': 'stale-while-revalidate',
    'stale_if_error': 'stale-if-error',
    'must_revalidate': 'must-revalidate',
    'no_cache': 'no-cache',
    'no_store': 'no-store',
    'no_transform': 'no-transform',
    'proxy_revalidate': 'proxy-revalidate',
    'immutable': 'immutable',
    'public': 'public',
    'private': 'private',
  };

  /// Headers a `304` drops, as Symfony's `setNotModified`.
  static const List<String> _notModifiedDrops = [
    'allow',
    'content-encoding',
    'content-language',
    'content-length',
    'content-md5',
    'content-type',
    'last-modified',
  ];

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    final cacheable = request.method == 'GET' || request.method == 'HEAD';
    final bytes = switch (response.body) {
      BytesBody(:final bytes) => bytes,
      _ => null,
    };
    final hasBody = response.body is StreamBody || (bytes?.isNotEmpty ?? false);
    if (!cacheable ||
        !hasBody ||
        response.status < 200 ||
        response.status >= 300) {
      return response;
    }
    final headers = response.headers.copy();
    if (options.containsKey('etag')) {
      final value = options['etag'];
      final etag =
          value ??
          headers.first('etag') ??
          (bytes == null ? null : '"${md5.convert(bytes)}"');
      if (etag != null) {
        headers.set(
          'etag',
          etag.startsWith('"') || etag.startsWith('W/') ? etag : '"$etag"',
        );
      }
    }
    final lastModified = options['last_modified'];
    if (lastModified != null) {
      final date = _date(lastModified);
      if (date != null) {
        headers.set('last-modified', HttpDate.format(date));
      }
    }
    headers.set('cache-control', _cacheControl(headers));
    if (_notModified(request, headers)) {
      for (final name in _notModifiedDrops) {
        headers.remove(name);
      }
      return Response(status: 304, headers: headers);
    }
    return Response(
      status: response.status,
      headers: headers,
      body: response.body,
      contentLengthOverride: response.contentLengthOverride,
    );
  }

  String _cacheControl(Headers headers) {
    final directives = <String, String?>{};
    for (final part in (headers.first('cache-control') ?? '').split(',')) {
      final directive = part.trim();
      if (directive.isNotEmpty) {
        final eq = directive.indexOf('=');
        directives[eq < 0 ? directive : directive.substring(0, eq)] = eq < 0
            ? null
            : directive.substring(eq + 1);
      }
    }
    for (final MapEntry(:key, :value) in options.entries) {
      final directive = _directives[key];
      if (directive == null) {
        continue;
      }
      if (key == 'public') {
        directives.remove('private');
      } else if (key == 'private') {
        directives.remove('public');
      }
      directives[directive] = value;
    }
    if (directives.isEmpty) {
      return headers.has('last-modified') || headers.has('expires')
          ? 'private, must-revalidate'
          : 'no-cache, private';
    }
    final keys = directives.keys.toList()..sort();
    final value = [
      for (final key in keys)
        directives[key] == null ? key : '$key=${directives[key]}',
    ].join(', ');
    return directives.containsKey('public') ||
            directives.containsKey('private') ||
            directives.containsKey('s-maxage')
        ? value
        : '$value, private';
  }

  /// Symfony's `isNotModified` (RFC 7232: `If-Modified-Since` only without
  /// `If-None-Match`).
  static bool _notModified(Request request, Headers headers) {
    final ifNoneMatch = request.header('if-none-match');
    final etag = headers.first('etag');
    if (ifNoneMatch != null && ifNoneMatch.isNotEmpty) {
      if (etag == null) {
        return false;
      }
      String weakless(String tag) =>
          tag.startsWith('W/') ? tag.substring(2) : tag;
      final current = weakless(etag);
      return ifNoneMatch
          .split(',')
          .map((tag) => weakless(tag.trim()))
          .any((tag) => tag == '*' || tag == current);
    }
    final since = request.header('if-modified-since');
    final modified = headers.first('last-modified');
    if (since == null || modified == null) {
      return false;
    }
    try {
      return !HttpDate.parse(since).isBefore(HttpDate.parse(modified));
    } on HttpException {
      return false;
    }
  }

  static DateTime? _date(String value) {
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
    try {
      return HttpDate.parse(value);
    } on HttpException {
      return DateTime.tryParse(value)?.toUtc();
    }
  }
}

/// Compresses responses with gzip for clients that accept it
/// (`Accept-Encoding: gzip`): bodies of at least [minLength] bytes with a
/// compressible type (JSON, text, XML, SVG, JavaScript). Streams (server-sent
/// events, downloads) are left alone. A strong `ETag` becomes weak, as the
/// bytes change with the encoding.
///
/// Behind a proxy that compresses (Caddy, nginx), leave this out.
final class CompressResponseMiddleware implements Middleware {
  const CompressResponseMiddleware({this.minLength = 1024, this.level = 6});

  final int minLength;

  /// gzip level, 1 (fastest) to 9 (smallest).
  final int level;

  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    if (!_acceptsGzip(request.header('accept-encoding'))) {
      return response;
    }
    final bytes = switch (response.body) {
      BytesBody(:final bytes) => bytes,
      _ => null,
    };
    if (bytes == null ||
        bytes.length < minLength ||
        response.status == 204 ||
        response.status == 304 ||
        response.headers.has('content-encoding') ||
        !compressible(response.headers.first('content-type'))) {
      return response;
    }
    final headers = response.headers.copy()
      ..set('content-encoding', 'gzip')
      ..remove('content-length');
    final vary = headers.first('vary');
    if (vary == null) {
      headers.set('vary', 'Accept-Encoding');
    } else if (!vary.toLowerCase().contains('accept-encoding')) {
      headers.set('vary', '$vary, Accept-Encoding');
    }
    final etag = headers.first('etag');
    if (etag != null && !etag.startsWith('W/')) {
      headers.set('etag', 'W/$etag');
    }
    return Response(
      status: response.status,
      headers: headers,
      body: BytesBody(GZipCodec(level: level).encode(bytes)),
    );
  }

  /// Whether [contentType] is worth compressing.
  static bool compressible(String? contentType) {
    if (contentType == null) {
      return false;
    }
    final type = contentType.split(';').first.trim().toLowerCase();
    return type.startsWith('text/') ||
        type == 'application/json' ||
        type.endsWith('+json') ||
        type == 'application/xml' ||
        type.endsWith('+xml') ||
        type == 'application/javascript' ||
        type == 'image/svg+xml';
  }

  static bool _acceptsGzip(String? header) {
    if (header == null) {
      return false;
    }
    for (final part in header.split(',')) {
      final pieces = part.split(';');
      final coding = pieces.first.trim().toLowerCase();
      if (coding != 'gzip' && coding != '*') {
        continue;
      }
      final q = pieces
          .skip(1)
          .map((p) => p.trim())
          .where((p) => p.startsWith('q='))
          .map((p) => double.tryParse(p.substring(2)) ?? 1)
          .firstOrNull;
      return (q ?? 1) > 0;
    }
    return false;
  }
}
