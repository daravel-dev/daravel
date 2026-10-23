import 'dart:convert';

import '../../http/request.dart';
import '../../http/response.dart';

/// Laravel-compatible `paginate()` result (`current_page`, `data`, `total`,
/// `links`...). Serializes exactly like `LengthAwarePaginator`.
final class LengthAwarePaginator<T> implements JsonSerializable, Responsable {
  LengthAwarePaginator({
    required this.items,
    required this.total,
    required this.perPage,
    required this.currentPage,
    this.path = '/',
    this.pageName = 'page',
    this.query = const <String, String>{},
  });

  final List<T> items;
  final int total;
  final int perPage;
  final int currentPage;
  final String path;
  final String pageName;
  final Map<String, String> query;

  int get lastPage => total == 0 ? 1 : (total / perPage).ceil();
  int? get from => items.isEmpty ? null : (currentPage - 1) * perPage + 1;
  int? get to =>
      items.isEmpty ? null : (currentPage - 1) * perPage + items.length;
  bool get hasMorePages => currentPage < lastPage;
  bool get onFirstPage => currentPage <= 1;

  String url(int page) {
    final params = <String, String>{...query, pageName: '$page'};
    final q = Uri(queryParameters: params).query;
    return '$path?$q';
  }

  String? get nextPageUrl => hasMorePages ? url(currentPage + 1) : null;
  String? get previousPageUrl => onFirstPage ? null : url(currentPage - 1);

  /// Laravel's `links` array (window of 3 pages around the current page,
  /// first/last pages and `...` separators).
  List<Map<String, Object?>> get links {
    final result = <Map<String, Object?>>[
      {'url': previousPageUrl, 'label': '&laquo; Previous', 'active': false},
    ];
    final pages = <int?>[];
    if (lastPage <= 13) {
      pages.addAll(List<int>.generate(lastPage, (i) => i + 1));
    } else {
      final window = <int>{1, 2, lastPage - 1, lastPage};
      for (var p = currentPage - 3; p <= currentPage + 3; p++) {
        if (p >= 1 && p <= lastPage) {
          window.add(p);
        }
      }
      final sorted = window.toList()..sort();
      int? previous;
      for (final page in sorted) {
        if (previous != null && page - previous > 1) {
          pages.add(null);
        }
        pages.add(page);
        previous = page;
      }
    }
    for (final page in pages) {
      if (page == null) {
        result.add({'url': null, 'label': '...', 'active': false});
      } else {
        result.add({
          'url': url(page),
          'label': '$page',
          'active': page == currentPage,
        });
      }
    }
    result.add({'url': nextPageUrl, 'label': 'Next &raquo;', 'active': false});
    return result;
  }

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

/// `simplePaginate()` result: no total, only next/previous.
final class SimplePaginator<T> implements JsonSerializable, Responsable {
  SimplePaginator({
    required this.items,
    required this.perPage,
    required this.currentPage,
    required this.hasMorePages,
    this.path = '/',
    this.pageName = 'page',
    this.query = const <String, String>{},
  });

  final List<T> items;
  final int perPage;
  final int currentPage;
  final bool hasMorePages;
  final String path;
  final String pageName;
  final Map<String, String> query;

  String url(int page) =>
      '$path?${Uri(queryParameters: <String, String>{...query, pageName: '$page'}).query}';

  String? get nextPageUrl => hasMorePages ? url(currentPage + 1) : null;
  String? get previousPageUrl => currentPage <= 1 ? null : url(currentPage - 1);

  @override
  Map<String, Object?> toJson() => {
    'current_page': currentPage,
    'data': items,
    'first_page_url': url(1),
    'from': items.isEmpty ? null : (currentPage - 1) * perPage + 1,
    'next_page_url': nextPageUrl,
    'path': path,
    'per_page': perPage,
    'prev_page_url': previousPageUrl,
    'to': items.isEmpty ? null : (currentPage - 1) * perPage + items.length,
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());
}

/// Opaque cursor for [CursorPaginator]: base64 JSON of the ordered column
/// values of the boundary row plus the direction.
final class Cursor {
  const Cursor(this.values, {this.pointsToNext = true});

  final Map<String, Object?> values;
  final bool pointsToNext;

  static Cursor? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
    );
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final direction = decoded.remove('_pointsToNext');
    return Cursor(decoded, pointsToNext: direction != false);
  }

  String encode() => base64Url.encode(
    utf8.encode(
      jsonEncode(<String, Object?>{...values, '_pointsToNext': pointsToNext}),
    ),
  );
}

/// `cursorPaginate()` result (keyset pagination).
final class CursorPaginator<T> implements JsonSerializable, Responsable {
  CursorPaginator({
    required this.items,
    required this.perPage,
    required this.nextCursor,
    required this.previousCursor,
    this.path = '/',
    this.cursorName = 'cursor',
    this.query = const <String, String>{},
  });

  final List<T> items;
  final int perPage;
  final Cursor? nextCursor;
  final Cursor? previousCursor;
  final String path;
  final String cursorName;
  final Map<String, String> query;

  String? _url(Cursor? cursor) => cursor == null
      ? null
      : '$path?${Uri(queryParameters: <String, String>{...query, cursorName: cursor.encode()}).query}';

  @override
  Map<String, Object?> toJson() => {
    'data': items,
    'path': path,
    'per_page': perPage,
    'next_cursor': nextCursor?.encode(),
    'next_page_url': _url(nextCursor),
    'prev_cursor': previousCursor?.encode(),
    'prev_page_url': _url(previousCursor),
  };

  @override
  Response toResponse(Request request) => Response.json(toJson());
}
