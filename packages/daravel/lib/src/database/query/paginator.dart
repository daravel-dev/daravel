import 'dart:convert';

import '../../foundation/container.dart';
import '../../http/request.dart';
import '../../http/response.dart';

/// Resolves pagination input from the current request, like Laravel's
/// `PaginationState` (page from the query string, path from
/// `$request->url()`). Outside a request it falls back to page 1 and `/`.
abstract final class Pagination {
  static Request? _request() {
    try {
      return Container.current.currentScope?.get<Request>();
    } on StateError {
      return null;
    }
  }

  /// `?page=` of the current request (1 when missing or invalid).
  static int resolvePage([String pageName = 'page']) {
    final page = int.tryParse(_request()?.query[pageName] ?? '');
    return page != null && page >= 1 ? page : 1;
  }

  /// Absolute URL of the current request without query string.
  static String resolvePath() => _request()?.url ?? '/';

  /// Query parameters of the current request (for `withQueryString()`).
  static Map<String, String> resolveQuery() =>
      _request()?.query ?? const <String, String>{};

  /// `?cursor=` of the current request.
  static Cursor? resolveCursor([String cursorName = 'cursor']) =>
      Cursor.decode(_request()?.query[cursorName]);
}

/// Base of the three paginators: path, extra query parameters and the
/// Laravel URL format (`path?query&page=N`, RFC 3986 encoding).
abstract base class _UrlPaginator {
  _UrlPaginator({required String path, required this.query})
    : path = path != '/' ? path.replaceAll(RegExp(r'/+$'), '') : path;

  /// Base URL of the paginated resource (Laravel `path()`).
  final String path;

  /// Query parameters appended to every page URL (`appends()`,
  /// `withQueryString()`).
  final Map<String, String> query;

  String _build(Map<String, String> parameters) =>
      '$path${path.contains('?') ? '&' : '?'}${rfc3986Query(parameters)}';
}

/// `paginate()` result. Serializes exactly like Laravel's
/// `LengthAwarePaginator` (key order, `links` with `page`, URL window).
final class LengthAwarePaginator<T> extends _UrlPaginator
    implements JsonSerializable, Responsable {
  LengthAwarePaginator({
    required this.items,
    required this.total,
    required this.perPage,
    required this.currentPage,
    super.path = '/',
    this.pageName = 'page',
    super.query = const <String, String>{},
    this.onEachSide = 3,
  });

  final List<T> items;
  final int total;
  final int perPage;
  final int currentPage;
  final String pageName;

  /// Pages shown on each side of the current one in [links].
  final int onEachSide;

  int get lastPage => total == 0 ? 1 : (total / perPage).ceil();
  int? get from => items.isEmpty ? null : (currentPage - 1) * perPage + 1;
  int? get to =>
      items.isEmpty ? null : (currentPage - 1) * perPage + items.length;
  bool get hasMorePages => currentPage < lastPage;
  bool get onFirstPage => currentPage <= 1;

  String url(int page) =>
      _build(<String, String>{...query, pageName: '${page < 1 ? 1 : page}'});

  String? get nextPageUrl => hasMorePages ? url(currentPage + 1) : null;
  String? get previousPageUrl => currentPage > 1 ? url(currentPage - 1) : null;

  /// Laravel's `linkCollection()`: previous, the `UrlWindow` pages with
  /// `...` separators, next.
  List<Map<String, Object?>> get links => <Map<String, Object?>>[
    {
      'url': previousPageUrl,
      'label': '&laquo; Previous',
      'page': currentPage > 1 ? currentPage - 1 : null,
      'active': false,
    },
    for (final page in urlWindow(currentPage, lastPage, onEachSide))
      if (page == null)
        {'url': null, 'label': '...', 'active': false}
      else
        {
          'url': url(page),
          'label': '$page',
          'page': page,
          'active': page == currentPage,
        },
    {
      'url': nextPageUrl,
      'label': 'Next &raquo;',
      'page': hasMorePages ? currentPage + 1 : null,
      'active': false,
    },
  ];

  /// Keeps the current request's query string in page URLs.
  LengthAwarePaginator<T> withQueryString() =>
      appends(Pagination.resolveQuery());

  /// Adds [parameters] to every page URL.
  LengthAwarePaginator<T> appends(Map<String, String> parameters) =>
      LengthAwarePaginator<T>(
        items: items,
        total: total,
        perPage: perPage,
        currentPage: currentPage,
        path: path,
        pageName: pageName,
        query: <String, String>{...query, ...parameters}..remove(pageName),
        onEachSide: onEachSide,
      );

  /// Maps the items, keeping pagination metadata.
  LengthAwarePaginator<R> map<R>(R Function(T item) transform) =>
      LengthAwarePaginator<R>(
        items: items.map(transform).toList(),
        total: total,
        perPage: perPage,
        currentPage: currentPage,
        path: path,
        pageName: pageName,
        query: query,
        onEachSide: onEachSide,
      );

  @override
  Map<String, Object?> toJson() => {
    'current_page': currentPage,
    'data': items,
    'first_page_url': url(1),
    'from': from,
    'last_page': lastPage,
    'last_page_url': url(lastPage),
    'links': links,
    'next_page_url': nextPageUrl,
    'path': path,
    'per_page': perPage,
    'prev_page_url': previousPageUrl,
    'to': to,
    'total': total,
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());
}

/// Laravel's `UrlWindow`: all pages when there are fewer than
/// `onEachSide * 2 + 8`, otherwise the first/last two pages and a slider
/// around [current]. `null` stands for a `...` separator.
List<int?> urlWindow(int current, int last, [int onEachSide = 3]) {
  List<int> range(int from, int to) => [for (var p = from; p <= to; p++) p];
  if (last < onEachSide * 2 + 8) {
    return range(1, last);
  }
  final window = onEachSide + 4;
  if (current <= window) {
    return [...range(1, window + onEachSide), null, last - 1, last];
  }
  if (current > last - window) {
    return [1, 2, null, ...range(last - (window + (onEachSide - 1)), last)];
  }
  return [
    1,
    2,
    null,
    ...range(current - onEachSide, current + onEachSide),
    null,
    last - 1,
    last,
  ];
}

/// `simplePaginate()` result: no total, only next/previous.
final class SimplePaginator<T> extends _UrlPaginator
    implements JsonSerializable, Responsable {
  SimplePaginator({
    required this.items,
    required this.perPage,
    required this.currentPage,
    required this.hasMorePages,
    super.path = '/',
    this.pageName = 'page',
    super.query = const <String, String>{},
  });

  final List<T> items;
  final int perPage;
  final int currentPage;
  final bool hasMorePages;
  final String pageName;

  int? get from => items.isEmpty ? null : (currentPage - 1) * perPage + 1;
  int? get to =>
      items.isEmpty ? null : (currentPage - 1) * perPage + items.length;

  String url(int page) =>
      _build(<String, String>{...query, pageName: '${page < 1 ? 1 : page}'});

  String? get nextPageUrl => hasMorePages ? url(currentPage + 1) : null;
  String? get previousPageUrl => currentPage > 1 ? url(currentPage - 1) : null;

  /// Keeps the current request's query string in page URLs.
  SimplePaginator<T> withQueryString() => appends(Pagination.resolveQuery());

  /// Adds [parameters] to every page URL.
  SimplePaginator<T> appends(Map<String, String> parameters) =>
      SimplePaginator<T>(
        items: items,
        perPage: perPage,
        currentPage: currentPage,
        hasMorePages: hasMorePages,
        path: path,
        pageName: pageName,
        query: <String, String>{...query, ...parameters}..remove(pageName),
      );

  @override
  Map<String, Object?> toJson() => {
    'current_page': currentPage,
    'current_page_url': url(currentPage),
    'data': items,
    'first_page_url': url(1),
    'from': from,
    'next_page_url': nextPageUrl,
    'path': path,
    'per_page': perPage,
    'prev_page_url': previousPageUrl,
    'to': to,
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());
}

/// Opaque cursor for [CursorPaginator], encoded like Laravel's `Cursor`:
/// URL-safe unpadded base64 of the PHP JSON of the boundary row's ordered
/// column values plus `_pointsToNextItems`, so cursors are interchangeable
/// with a Laravel app over the same table.
final class Cursor {
  const Cursor(this.values, {this.pointsToNext = true});

  final Map<String, Object?> values;
  final bool pointsToNext;

  static Cursor? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
      );
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final direction = decoded.remove('_pointsToNextItems');
      return Cursor(decoded, pointsToNext: direction != false);
    } on FormatException {
      return null;
    }
  }

  String encode() => base64Url
      .encode(
        utf8.encode(
          phpJsonEncode(<String, Object?>{
            ...values,
            '_pointsToNextItems': pointsToNext,
          }),
        ),
      )
      .replaceAll('=', '');
}

/// `cursorPaginate()` result (keyset pagination).
final class CursorPaginator<T> extends _UrlPaginator
    implements JsonSerializable, Responsable {
  CursorPaginator({
    required this.items,
    required this.perPage,
    required this.nextCursor,
    required this.previousCursor,
    super.path = '/',
    this.cursorName = 'cursor',
    super.query = const <String, String>{},
  });

  final List<T> items;
  final int perPage;
  final Cursor? nextCursor;
  final Cursor? previousCursor;
  final String cursorName;

  /// URL of the next page (`null` on the last page).
  String? get nextPageUrl => _url(nextCursor);

  /// URL of the previous page (`null` on the first page).
  String? get previousPageUrl => _url(previousCursor);

  String? _url(Cursor? cursor) => cursor == null
      ? null
      : _build(<String, String>{...query, cursorName: cursor.encode()});

  @override
  Map<String, Object?> toJson() => {
    'data': items,
    'path': path,
    'per_page': perPage,
    'next_cursor': nextCursor?.encode(),
    'next_page_url': nextPageUrl,
    'prev_cursor': previousCursor?.encode(),
    'prev_page_url': previousPageUrl,
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());
}

/// PHP `http_build_query(..., PHP_QUERY_RFC3986)` for flat parameters
/// (Laravel `Arr::query`): `rawurlencode` keys and values joined by `&`.
String rfc3986Query(Map<String, String> parameters) => [
  for (final entry in parameters.entries)
    '${_rawUrlEncode(entry.key)}=${_rawUrlEncode(entry.value)}',
].join('&');

String _rawUrlEncode(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E;
    out.write(
      unreserved
          ? String.fromCharCode(byte)
          : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
  return out.toString();
}

/// PHP `json_encode()` with default flags: like [jsonEncode], but `/` is
/// escaped as `\/` and non-ASCII characters as `\uXXXX` (UTF-16 units).
String phpJsonEncode(Object? value) {
  final out = StringBuffer();
  for (final unit in jsonEncode(value).codeUnits) {
    if (unit == 0x2F) {
      out.write(r'\/');
    } else if (unit > 0x7F) {
      out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}
