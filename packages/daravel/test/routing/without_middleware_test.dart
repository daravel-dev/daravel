import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Tagged implements Middleware {
  const Tagged(this.tag);
  final String tag;
  @override
  Future<Response> handle(Request request, Next next) async =>
      (await next(request)).withHeader('x-$tag', 'yes');
}

final class Other implements Middleware {
  const Other();
  @override
  Future<Response> handle(Request request, Next next) async =>
      (await next(request)).withHeader('x-other', 'yes');
}

void main() {
  late Directory base;
  late Application app;
  late TestClient client;

  final closure = FunctionalMiddleware((request, next) async {
    return (await next(request)).withHeader('x-closure', 'yes');
  });
  final keptClosure = FunctionalMiddleware((request, next) async {
    return (await next(request)).withHeader('x-kept', 'yes');
  });

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_without');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withMiddleware(
          (middleware) => middleware
            ..alias('tagged', const Tagged('a'))
            ..alias('other', const Other())
            ..alias('closure', closure)
            ..group('stack', const <Object>['tagged', 'other']),
        )
        .withRouting(
          web: (router) {
            router.group((r) {
              r.get('/all', (_) => 'x');
              r.get('/alias', (_) => 'x').withoutMiddleware(['tagged']);
              r.get('/group', (_) => 'x').withoutMiddleware(['stack']);
              r.get('/type', (_) => 'x').withoutMiddleware<Other>();
              r.get('/type-list', (_) => 'x').withoutMiddleware([Tagged]);
              r.get('/closure', (_) => 'x').withoutMiddleware(['closure']);
            }, middleware: ['stack', 'closure', keptClosure]);
          },
        )
        .create();
    await app.boot();
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<Set<String>> tags(String uri) async {
    final response = await client.get(uri);
    return {
      for (final name in ['a', 'other', 'closure', 'kept'])
        if (response.headers.first('x-$name') != null) name,
    };
  }

  test('without exclusions everything runs', () async {
    expect(await tags('/all'), {'a', 'other', 'closure', 'kept'});
  });

  test('an alias from an outer group', () async {
    expect(await tags('/alias'), {'other', 'closure', 'kept'});
  });

  test('a whole group', () async {
    expect(await tags('/group'), {'closure', 'kept'});
  });

  test('a type, written either way', () async {
    expect(await tags('/type'), {'a', 'closure', 'kept'});
    expect(await tags('/type-list'), {'other', 'closure', 'kept'});
  });

  test('a closure leaves alone, not all of them', () async {
    expect(await tags('/closure'), {'a', 'other', 'kept'});
  });
}
