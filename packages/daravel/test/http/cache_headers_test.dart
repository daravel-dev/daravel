import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Cache-Control values are Laravel 12's (SetCacheHeaders on Symfony 7),
/// captured by running the middleware; ETag values differ on purpose
/// (Laravel hashes with xxh128, Daravel with MD5).
void main() {
  late Application app;
  late TestClient client;
  final big = {
    'items': List.generate(200, (i) => {'id': i, 'name': 'item $i'}),
  };

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          api: (router) {
            for (final (path, options) in [
              ('/a', 'public;max_age=3600;etag'),
              ('/b', 'private;max_age=60'),
              ('/c', 'public;s_maxage=120;max_age=60;must_revalidate'),
              ('/d', 'no_cache;no_store'),
              ('/e', 'public;immutable;max_age=31536000'),
              ('/f', 'etag'),
            ]) {
              router.get(path, (_) => Response.json('hello world')).middleware([
                'cache.headers:$options',
              ]);
            }
            router.post('/a', (_) => Response.json('x')).middleware(const [
              'cache.headers:public;max_age=60;etag',
            ]);
            router
                .get('/missing', (_) => Response.json('nope', status: 404))
                .middleware(const ['cache.headers:public;max_age=60;etag']);
            router.get('/empty', (_) => Response.noContent()).middleware(const [
              'cache.headers:public;max_age=60;etag',
            ]);
            router
                .get(
                  '/localized',
                  (_) => Response.json(
                    'hello world',
                    headers: const {'content-language': 'en'},
                  ),
                )
                .middleware(const ['cache.headers:public;max_age=3600;etag']);
            router.get('/dated', (_) => Response.text('hello')).middleware(
              const ['cache.headers:public;last_modified=1792836000'],
            );
            router.get('/big', (_) => big);
            router.get('/small', (_) => {'ok': true});
            router.get(
              '/png',
              (_) => Response.bytes(
                List.filled(4096, 1),
                contentType: 'image/png',
              ),
            );
            router.get('/big-etag', (_) => big).middleware(const [
              'cache.headers:public;max_age=60;etag',
            ]);
          },
        )
        .withMiddleware((middleware) {
          middleware.use(const [CompressResponseMiddleware()]);
        })
        .create();
    await app.boot();
    client = TestClient(app);
  });
  tearDown(() => app.shutdown());

  test('Cache-Control as Laravel writes it', () async {
    final expected = {
      '/api/a': 'max-age=3600, public',
      '/api/b': 'max-age=60, private',
      '/api/c': 'max-age=60, must-revalidate, public, s-maxage=120',
      '/api/d': 'no-cache, no-store, private',
      '/api/e': 'immutable, max-age=31536000, public',
      '/api/f': 'no-cache, private',
    };
    for (final MapEntry(key: path, value: cacheControl) in expected.entries) {
      final response = await client.get(path);
      response
        ..assertOk()
        ..assertHeader('cache-control', cacheControl);
    }
    (await client.get('/api/a')).assertHeader('etag');
    (await client.get('/api/b')).assertHeaderMissing('etag');
    expect(
      (await client.get('/api/f')).headers['etag'],
      matches(RegExp(r'^"[0-9a-f]{32}"$')),
    );
  });

  test('only successful GET responses with a body are touched', () async {
    (await client.post(
      '/api/a',
      json: const {},
    )).assertHeaderMissing('cache-control');
    (await client.get('/api/missing')).assertHeaderMissing('cache-control');
    (await client.get('/api/empty')).assertHeaderMissing('cache-control');
  });

  test('If-None-Match answers 304 (exact, weak, list, *)', () async {
    final first = await client.get('/api/localized');
    final etag = first.headers['etag']!;
    for (final ifNoneMatch in [etag, 'W/$etag', '"other", $etag', '*']) {
      final response = await client.get(
        '/api/localized',
        headers: {'if-none-match': ifNoneMatch},
      );
      response
        ..assertStatus(304)
        ..assertHeader('etag', etag)
        ..assertHeader('cache-control', 'max-age=3600, public')
        ..assertHeaderMissing('content-type')
        ..assertHeaderMissing('content-language');
      expect(response.body, isEmpty, reason: ifNoneMatch);
    }
    (await client.get('/api/localized', headers: {'if-none-match': '"other"'}))
      ..assertOk()
      ..assertHeader('content-language', 'en');
  });

  test('If-Modified-Since with last_modified answers 304', () async {
    final fresh = await client.get('/api/dated');
    fresh
      ..assertOk()
      ..assertHeader('cache-control', 'public')
      ..assertHeader(
        'last-modified',
        HttpDate.format(
          DateTime.fromMillisecondsSinceEpoch(1792836000000, isUtc: true),
        ),
      );
    (await client.get(
        '/api/dated',
        headers: {'if-modified-since': 'Sat, 24 Oct 2026 10:00:00 GMT'},
      ))
      ..assertStatus(304)
      ..assertHeader('cache-control', 'public')
      ..assertHeaderMissing('last-modified');
    (await client.get(
      '/api/dated',
      headers: {'if-modified-since': 'Thu, 01 Jan 2026 00:00:00 GMT'},
    )).assertOk();
  });

  group('gzip', () {
    test(
      'compresses large compressible bodies for clients that accept it',
      () async {
        final response = await client.get(
          '/api/big',
          headers: {'accept-encoding': 'br, gzip;q=0.8'},
        );
        response
          ..assertOk()
          ..assertHeader('content-encoding', 'gzip')
          ..assertHeader('vary', 'Accept-Encoding');
        final plain = utf8.encode(jsonEncode(big));
        expect(response.bodyBytes.length, lessThan(plain.length ~/ 4));
        expect(jsonDecode(utf8.decode(gzip.decode(response.bodyBytes))), big);
      },
    );

    test('leaves small, binary and unrequested bodies alone', () async {
      for (final (path, headers) in [
        ('/api/big', <String, String>{}),
        ('/api/big', {'accept-encoding': 'gzip;q=0'}),
        ('/api/small', {'accept-encoding': 'gzip'}),
        ('/api/png', {'accept-encoding': 'gzip'}),
      ]) {
        (await client.get(
          path,
          headers: headers,
        )).assertHeaderMissing('content-encoding');
      }
    });

    test('a strong ETag becomes weak, and still revalidates', () async {
      final gzipped = await client.get(
        '/api/big-etag',
        headers: {'accept-encoding': 'gzip'},
      );
      final etag = gzipped.headers['etag']!;
      expect(etag, startsWith('W/"'));
      (await client.get(
        '/api/big-etag',
        headers: {'accept-encoding': 'gzip', 'if-none-match': etag},
      )).assertStatus(304);
    });
  });

  test('options parse as Laravel parses them', () {
    expect(CacheHeadersMiddleware.parseOptions('public;max_age=3600;etag;'), {
      'public': null,
      'max_age': '3600',
      'etag': null,
    });
  });
}
