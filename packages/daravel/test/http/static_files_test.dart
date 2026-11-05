import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> text(Response response) async {
  final body = response.body as StreamBody;
  return utf8.decode(await body.stream.expand((chunk) => chunk).toList());
}

void main() {
  late Directory base;
  late String public;

  void write(String path, String contents) {
    File(p.join(base.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  setUp(() {
    base = Directory.systemTemp.createTempSync('daravel_static');
    public = p.join(base.path, 'public');
    write('public/neo.css', 'body{}');
    write('public/fonts/inter.woff2', 'woff2');
    write('public/js/app.js', 'console.log(1)');
    write('public/app.wasm', 'wasm');
    write('public/logo.svg', '<svg/>');
    write('public/my file.txt', 'spaced');
    write('public/.env', 'APP_KEY=secret');
    write('public/.git/config', 'secret');
    write('secret.txt', 'outside');
    write('.env', 'SECRET=outside');
    write(
      'public/build/manifest.json',
      jsonEncode({
        'resources/js/app.js': {
          'file': 'assets/app-4ed993c7.js',
          'src': 'resources/js/app.js',
          'isEntry': true,
          'css': ['assets/app-1f2e3d4c.css'],
        },
      }),
    );
    write('public/build/assets/app-4ed993c7.js', 'built');
    write('public/build/assets/app-1f2e3d4c.css', 'built css');
  });

  tearDown(() {
    Container.setRoot(null);
    base.deleteSync(recursive: true);
  });

  Future<Application> boot({bool? rescan, String prefix = '/assets'}) async {
    final app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withStatic('public', prefix: prefix, rescan: rescan)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    return app;
  }

  Future<Response> get(
    Application app,
    String path, {
    Map<String, String>? headers,
  }) => app.handle(Request.fake(path: path, headers: headers));

  group('serving', () {
    test('a found file, with its type and a short max-age', () async {
      final app = await boot();
      final response = await get(app, '/assets/neo.css');
      expect(response.status, 200);
      expect(await text(response), 'body{}');
      expect(response.headers.first('content-type'), 'text/css');
      expect(response.headers.first('cache-control'), 'public, max-age=300');
      expect(response.headers.first('content-disposition'), isNull);
      expect(response.headers.first('x-content-type-options'), 'nosniff');
    });

    test('nested paths and encoded names', () async {
      final app = await boot();
      final font = await get(app, '/assets/fonts/inter.woff2');
      expect(font.status, 200);
      expect(font.headers.first('content-type'), 'font/woff2');
      final spaced = await get(app, '/assets/my%20file.txt');
      expect(await text(spaced), 'spaced');
    });

    test('types of fonts, modules, wasm and svg', () async {
      final app = await boot();
      final types = {
        '/assets/js/app.js': 'text/javascript',
        '/assets/app.wasm': 'application/wasm',
        '/assets/logo.svg': 'image/svg+xml',
      };
      for (final MapEntry(:key, :value) in types.entries) {
        final response = await get(app, key);
        expect(response.headers.first('content-type'), value, reason: key);
      }
      expect(mimeTypeOf('a.woff'), 'font/woff');
      expect(mimeTypeOf('a.ttf'), 'font/ttf');
      expect(mimeTypeOf('a.otf'), 'font/otf');
      expect(mimeTypeOf('a.mjs'), 'text/javascript');
      expect(mimeTypeOf('a.js.map'), 'application/json');
      expect(mimeTypeOf('A.WOFF2'), 'font/woff2');
      expect(mimeTypeOf('README'), 'application/octet-stream');
    });

    test('ETag gives 304, with the cache headers kept', () async {
      final app = await boot();
      final url = app.run(() => asset('neo.css'));
      final first = await get(app, await url);
      final etag = first.headers.first('etag')!;
      final second = await app.handle(
        Request.fake(path: await url, headers: {'if-none-match': etag}),
      );
      expect(second.status, 304);
      expect(second.headers.first('cache-control'), StaticFiles.immutable);
    });

    test('ranges come from Response.file', () async {
      final app = await boot();
      final response = await get(
        app,
        '/assets/neo.css',
        headers: {'range': 'bytes=0-3'},
      );
      expect(response.status, 206);
      expect(await text(response), 'body');
      expect(response.headers.first('content-range'), 'bytes 0-3/6');
    });

    test('HEAD answers like GET', () async {
      final app = await boot();
      final response = await app.handle(
        Request.fake(method: 'HEAD', path: '/assets/neo.css'),
      );
      expect(response.status, 200);
      expect(response.headers.first('content-length'), '6');
    });

    test('a root prefix serves from /', () async {
      final app = await boot(prefix: '/');
      expect((await get(app, '/neo.css')).status, 200);
      expect(await app.run(() => asset('neo.css')), startsWith('/neo.css?v='));
    });
  });

  group('traversal-proof', () {
    for (final path in [
      '/assets/../secret.txt',
      '/assets/%2e%2e/secret.txt',
      '/assets/%2E%2E/%2E%2E/secret.txt',
      '/assets/..%2fsecret.txt',
      '/assets/..%2F..%2Fsecret.txt',
      '/assets/..%5csecret.txt',
      '/assets/fonts/..%2f..%2fsecret.txt',
      '/assets/fonts/%2e%2e/%2e%2e/.env',
      '/assets/.env',
      '/assets/%2eenv',
      '/assets/%2eenv%00.css',
      '/assets/.git/config',
      '/assets/build/.vite/manifest.json',
      '/assets/neo.css%00.txt',
      '/assets//etc/passwd',
      '/assets/%2Fetc%2Fpasswd',
      '/assets/C:%5CWindows%5Cwin.ini',
      '/assets/NEO.CSS',
      '/assets/',
      '/assets',
    ]) {
      test('$path is a 404', () async {
        final app = await boot();
        final response = await get(app, path);
        expect(response.status, 404, reason: path);
      });
    }

    test('a file added after boot is not served', () async {
      final app = await boot(rescan: false);
      write('public/late.css', 'late');
      expect((await get(app, '/assets/late.css')).status, 404);
    });

    test('symbolic links are not followed', () async {
      final link = Link(p.join(public, 'storage'));
      try {
        link.createSync(base.path);
      } on FileSystemException {
        markTestSkipped('No permission to create symbolic links here.');
        return;
      }
      final app = await boot();
      expect((await get(app, '/assets/storage/secret.txt')).status, 404);
    });

    test('a missing directory aborts the boot', () async {
      final app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withStatic('missing')
          .create();
      addTearDown(app.shutdown);
      await expectLater(app.boot(), throwsA(isA<ConfigException>()));
    });
  });

  group('versions', () {
    test('asset() carries the SHA-256 prefix; it makes the answer '
        'immutable', () async {
      final app = await boot();
      final url = await app.run(() => asset('neo.css'));
      expect(url, matches(RegExp(r'^/assets/neo\.css\?v=[0-9a-f]{12}$')));
      final response = await get(app, url);
      expect(response.headers.first('cache-control'), StaticFiles.immutable);
    });

    test('a stale or wrong version gets the short max-age', () async {
      final app = await boot();
      final response = await get(app, '/assets/neo.css?v=000000000000');
      expect(response.status, 200);
      expect(response.headers.first('cache-control'), 'public, max-age=300');
    });

    test('names are encoded; unknown paths keep a plain URL', () async {
      final app = await boot();
      expect(
        await app.run(() => asset('my file.txt')),
        startsWith('/assets/my%20file.txt?v='),
      );
      expect(await app.run(() => asset('/neo.css')), contains('?v='));
      expect(await app.run(() => asset('nope.css')), '/assets/nope.css');
    });

    test('rescan picks up new and edited files', () async {
      final app = await boot(rescan: true);
      final before = await app.run(() => asset('neo.css'));
      write('public/neo.css', 'body{color:red}');
      final after = await app.run(() => asset('neo.css'));
      expect(after, isNot(before));
      write('public/late.css', 'late');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect((await get(app, '/assets/late.css')).status, 200);
    });

    test('APP_ENV=local rescans by default', () async {
      final app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'local', 'DB_DATABASE': ':memory:'})
          .withStatic('public')
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      expect(
        app.container.make<StaticAssets>().directories.single.rescan,
        isTrue,
      );
    });

    test('without withStatic, asset() gives a plain path', () async {
      final app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .create();
      addTearDown(app.shutdown);
      expect(await app.run(() => asset('neo.css')), '/neo.css');
    });
  });

  group('manifest (static:hash)', () {
    test('a recorded version is used while size and time match', () async {
      final files = StaticFiles(public)..scan();
      final real = files.version('neo.css')!;
      files.writeManifest();
      final manifest = File(p.join(public, StaticFiles.manifestName));
      final data =
          jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      final entries = data['files']! as Map<String, Object?>;
      expect(entries.keys, isNot(contains('.env')));
      expect((entries['neo.css']! as Map<String, Object?>)['hash'], real);

      // A forged hash proves the boot read the manifest, not the file.
      (entries['neo.css']! as Map<String, Object?>)['hash'] = 'cafebabe0000';
      manifest.writeAsStringSync(jsonEncode(data));
      final production = StaticFiles(public)..scan();
      expect(production.version('neo.css'), 'cafebabe0000');
      expect(production.has(StaticFiles.manifestName), isFalse);

      // A file changed after static:hash is hashed again.
      write('public/neo.css', 'body{margin:0}');
      final changed = StaticFiles(public)..scan();
      expect(changed.version('neo.css'), isNot('cafebabe0000'));
      expect(changed.version('neo.css'), isNot(real));
    });
  });

  group('Vite', () {
    test('Assets.vite gives the built file; it is immutable', () async {
      final app = await boot();
      final url = await app.run(() => Assets.vite('resources/js/app.js'));
      expect(url, '/assets/build/assets/app-4ed993c7.js');
      expect(
        await app.run(() => asset('resources/js/app.js')),
        '/assets/build/assets/app-4ed993c7.js',
      );
      final js = await get(app, url);
      expect(js.headers.first('cache-control'), StaticFiles.immutable);
      final css = await get(app, '/assets/build/assets/app-1f2e3d4c.css');
      expect(css.headers.first('cache-control'), StaticFiles.immutable);
    });

    test('an entry missing from the manifest throws', () async {
      final app = await boot();
      await expectLater(
        app.run(() => Assets.vite('resources/js/missing.js')),
        throwsStateError,
      );
    });

    test('plain Vite writes .vite/manifest.json', () async {
      File(p.join(public, 'build', 'manifest.json')).deleteSync();
      write(
        'public/build/.vite/manifest.json',
        jsonEncode({
          'src/main.ts': {'file': 'assets/main-abc.js', 'isEntry': true},
        }),
      );
      final files = StaticFiles(public)..scan();
      expect(files.viteUrl('src/main.ts'), '/assets/build/assets/main-abc.js');
    });
  });
}
