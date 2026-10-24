@Tags(['conformance'])
library;

import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import 'conformance_app.dart';

/// Paginator and resource JSON locked to Laravel 12 (`Pagination/*`,
/// `UrlWindow`, `PaginatedResourceResponse`, `Cursor`).
void main() {
  group('UrlWindow', () {
    // Hand-derived from Pagination/UrlWindow.php (onEachSide = 3).
    const fixtures = <(int, int), List<int?>>{
      (1, 1): [1],
      (1, 13): [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
      (1, 14): [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, null, 13, 14],
      (7, 20): [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, null, 19, 20],
      (8, 20): [1, 2, null, 5, 6, 7, 8, 9, 10, 11, null, 19, 20],
      (13, 20): [1, 2, null, 10, 11, 12, 13, 14, 15, 16, null, 19, 20],
      (14, 20): [1, 2, null, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
      (20, 20): [1, 2, null, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
    };
    fixtures.forEach((key, expected) {
      final (current, last) = key;
      test('page $current of $last', () {
        expect(urlWindow(current, last), expected);
        expect(LaravelContract.urlWindow(current, last), expected);
      });
    });

    test('paginator links follow the window for every page of 1..30', () {
      for (var last = 1; last <= 30; last++) {
        for (var page = 1; page <= last; page++) {
          final paginator = LengthAwarePaginator<int>(
            items: const [1],
            total: last * 2,
            perPage: 2,
            currentPage: page,
            path: 'http://localhost/posts',
          );
          expect(
            jsonDecode(jsonEncode(paginator.toJson())),
            isLaravelLengthAwarePaginator(),
            reason: 'page $page of $last',
          );
        }
      }
    });
  });

  group('over HTTP', () {
    late Application app;
    late TestClient client;

    setUp(() async {
      (app, client) = await bootConformanceApp();
      await seedPosts(app, 5);
    });
    tearDown(() => app.shutdown());

    test('paginate(): Laravel body, absolute URLs from the request', () async {
      final res = await client.get('/api/posts?page=2&sort=x');
      res.assertOk();
      expect(res.json, isLaravelLengthAwarePaginator());
      expect(res.json, <String, Object?>{
        'current_page': 2,
        'data': [
          {'id': 3, 'title': 'Post 3'},
          {'id': 4, 'title': 'Post 4'},
        ],
        'first_page_url': 'http://localhost/api/posts?page=1',
        'from': 3,
        'last_page': 3,
        'last_page_url': 'http://localhost/api/posts?page=3',
        'links': [
          {
            'url': 'http://localhost/api/posts?page=1',
            'label': '&laquo; Previous',
            'page': 1,
            'active': false,
          },
          {
            'url': 'http://localhost/api/posts?page=1',
            'label': '1',
            'page': 1,
            'active': false,
          },
          {
            'url': 'http://localhost/api/posts?page=2',
            'label': '2',
            'page': 2,
            'active': true,
          },
          {
            'url': 'http://localhost/api/posts?page=3',
            'label': '3',
            'page': 3,
            'active': false,
          },
          {
            'url': 'http://localhost/api/posts?page=3',
            'label': 'Next &raquo;',
            'page': 3,
            'active': false,
          },
        ],
        'next_page_url': 'http://localhost/api/posts?page=3',
        'path': 'http://localhost/api/posts',
        'per_page': 2,
        'prev_page_url': 'http://localhost/api/posts?page=1',
        'to': 4,
        'total': 5,
      });
    });

    test('an empty page has null from/to and last_page 1', () async {
      await app.run(() => DB.table('posts').delete());
      final res = await client.get('/api/posts');
      expect(res.jsonMap['from'], isNull);
      expect(res.jsonMap['to'], isNull);
      expect(res.jsonMap['last_page'], 1);
      expect(res.json, isLaravelLengthAwarePaginator());
    });

    test('invalid ?page falls back to 1', () async {
      for (final page in ['0', '-3', 'abc', '']) {
        final res = await client.get('/api/posts?page=$page');
        expect(res.jsonMap['current_page'], 1, reason: 'page=$page');
      }
    });

    test('simplePaginate(): Laravel key order with current_page_url', () async {
      final res = await client.get('/api/posts/simple?page=3');
      expect(res.jsonMap.keys, LaravelContract.simplePaginatorKeys);
      expect(
        res.jsonMap['current_page_url'],
        'http://localhost/api/posts/simple?page=3',
      );
      expect(res.jsonMap['next_page_url'], isNull);
      expect(res.jsonMap['from'], 5);
      expect(res.jsonMap['to'], 5);
    });

    test(
      'cursorPaginate(): Laravel keys and Laravel-encoded cursors',
      () async {
        final first = await client.get('/api/posts/cursor');
        expect(first.jsonMap.keys, LaravelContract.cursorPaginatorKeys);
        final next = first.jsonMap['next_cursor']! as String;
        // Laravel: URL-safe base64 without padding of {"id":2,"_pointsToNextItems":true}.
        expect(
          next,
          base64Url
              .encode(utf8.encode('{"id":2,"_pointsToNextItems":true}'))
              .replaceAll('=', ''),
        );
        expect(next, isNot(contains('=')));
        final second = await client.get('/api/posts/cursor?cursor=$next');
        expect(
          [
            for (final p in second.jsonMap['data']! as List<Object?>)
              (p! as Map<String, Object?>)['id'],
          ],
          [3, 4],
        );
        expect(second.jsonMap['prev_cursor'], isNotNull);
      },
    );

    test('a cursor produced by Laravel is accepted', () async {
      // Cursor::encode() of ['id' => 4, '_pointsToNextItems' => true].
      const laravelCursor = 'eyJpZCI6NCwiX3BvaW50c1RvTmV4dEl0ZW1zIjp0cnVlfQ';
      final res = await client.get('/api/posts/cursor?cursor=$laravelCursor');
      expect(
        [
          for (final p in res.jsonMap['data']! as List<Object?>)
            (p! as Map<String, Object?>)['id'],
        ],
        [5],
      );
    });

    test('cursor JSON escapes like PHP json_encode', () {
      final cursor = Cursor({'slug': 'a/b', 'name': 'é'});
      final json = utf8.decode(
        base64Url.decode(base64Url.normalize(cursor.encode())),
      );
      expect(
        json,
        '{"slug":"a${r'\'}/b","name":"${r'\'}u00e9","_pointsToNextItems":true}',
      );
      expect(Cursor.decode(cursor.encode())!.values, {
        'slug': 'a/b',
        'name': 'é',
      });
    });

    test('URLs are RFC 3986 encoded like Arr::query', () {
      final paginator = LengthAwarePaginator<int>(
        items: const [1],
        total: 1,
        perPage: 1,
        currentPage: 1,
        path: 'http://localhost/search',
        query: const {'q': 'a b&c', 'tag': '~x*'},
      );
      expect(
        paginator.url(1),
        'http://localhost/search?q=a%20b%26c&tag=~x%2A&page=1',
      );
    });

    group('resources', () {
      test(
        'paginate() → {data, links, meta} like PaginatedResourceResponse',
        () async {
          // The same paginator as /api/posts, seen from the resource route.
          final raw = jsonDecode(
            (await client.get('/api/posts?page=2')).body.replaceAll(
              'http://localhost/api/posts',
              'http://localhost/api/posts/resource',
            ),
          ) as Map<String, Object?>;
          final res = await client.get('/api/posts/resource?page=2');
          expect(res.json, isLaravelPaginatedResource(raw));
          expect(res.jsonMap.keys, ['data', 'links', 'meta']);
          final meta = res.jsonMap['meta']! as Map<String, Object?>;
          expect(meta.keys, [
            'current_page',
            'from',
            'last_page',
            'links',
            'path',
            'per_page',
            'to',
            'total',
          ]);
          expect(meta['path'], 'http://localhost/api/posts/resource');
        },
      );

      test('simplePaginate() meta keeps current_page_url', () async {
        final raw = (await client.get('/api/posts/simple')).jsonMap;
        final res = await client.get('/api/posts/resource/simple');
        final meta = res.jsonMap['meta']! as Map<String, Object?>;
        expect(meta.keys, [
          'current_page',
          'current_page_url',
          'from',
          'path',
          'per_page',
          'to',
        ]);
        final links = res.jsonMap['links']! as Map<String, Object?>;
        expect(links['last'], isNull);
        expect(raw['current_page'], meta['current_page']);
      });

      test('cursorPaginate() meta is path, per_page and the cursors', () async {
        final res = await client.get('/api/posts/resource/cursor');
        final meta = res.jsonMap['meta']! as Map<String, Object?>;
        expect(meta.keys, ['path', 'per_page', 'next_cursor', 'prev_cursor']);
        final links = res.jsonMap['links']! as Map<String, Object?>;
        expect(links['first'], isNull);
        expect(links['last'], isNull);
      });

      test('a resource of a just-created model answers 201 '
          '(wasRecentlyCreated)', () async {
        final res = await client.post('/api/posts', json: {'title': 'New'});
        res.assertCreated();
        expect(res.jsonMap['data'], {'id': 6, 'title': 'New'});
        (await client.get('/api/posts/6/resource')).assertOk();
      });

      test('a single resource is wrapped in data', () async {
        final res = await client.get('/api/posts/1/resource');
        expect(res.json, {
          'data': {'id': 1, 'title': 'Post 1'},
        });
      });
    });
  });
}
