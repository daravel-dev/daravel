import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Tenant extends Model {
  static final ModelDefinition<Tenant> definition = ModelDefinition<Tenant>(
    table: 'tenants',
    factory: Tenant.new,
    timestamps: false,
    relations: {
      'exams': () =>
          HasMany<Exam>(() => Exam.definition, foreignKey: 'tenant_id'),
    },
  );
  @override
  ModelDefinition<Tenant> get modelDefinition => definition;
}

final class Exam extends Model {
  static final ModelDefinition<Exam> definition = ModelDefinition<Exam>(
    table: 'exams',
    factory: Exam.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Exam> get modelDefinition => definition;
}

void main() {
  late Directory base;
  late Application app;
  late TestClient client;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_domain');
    app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        })
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router
              ..bindModel('tenant', Tenant.definition)
              ..bindModel('exam', Exam.definition);
            router.group((r) {
              r.get('/who', (q) => 'tenant ${q.routeParams['org']}');
            }, domain: '{org}.first.test');
            router.group((r) {
              r.get('/who', (_) => 'admin');
            }, domain: 'admin.first.test');
            router
                .get('/export', (_) => 'exported')
                .domain('{org}.sign.test')
                .name('export')
                .middleware(['signed']);
            router
                .get('/plain-signed', (_) => 'ok')
                .name('plain-signed')
                .middleware(['signed']);
            router.get('/', (_) => 'plain');
            router.get('/same', (_) => 'plain');
            router.post('/only-post', (_) => 'plain');
            router.group((r) {
              r.get('/', (_) => 'admin').name('admin.home');
              r.get('/same', (_) => 'admin');
            }, domain: 'admin.example.com');
            router.group(
              (r) {
                r.get('/', (q) => 'site ${q.routeParams['site']}');
                r.get('/page/{id}', (q) => q.routeParams).name('site.page');
                r.group((inner) {
                  inner.get('/nested', (q) => q.routeParams['site']);
                }, prefix: '/in');
              },
              domain: '{site}.example.org',
              where: {'site': '[a-z]+'},
            );
            router.get('/fluent', (_) => 'fluent').domain('api.example.net');
            router
                .get(
                  '/exams/{exam}',
                  (q) => {'id': q.binding<Exam>('exam').getAttr<int>('id')},
                )
                .domain('{tenant:slug}.exams.test')
                .scopeBindings();
          },
        )
        .create();
    await app.boot();
    await app.run(() async {
      await DB.statement(
        'CREATE TABLE tenants (id INTEGER PRIMARY KEY, slug TEXT)',
      );
      await DB.statement(
        'CREATE TABLE exams (id INTEGER PRIMARY KEY, tenant_id INTEGER)',
      );
      await DB.table('tenants').insert([
        {'id': 1, 'slug': 'one'},
        {'id': 2, 'slug': 'two'},
      ]);
      await DB.table('exams').insert([
        {'id': 10, 'tenant_id': 1},
        {'id': 20, 'tenant_id': 2},
      ]);
    });
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<TestResponse> at(String host, String path) =>
      client.get(path, headers: {'host': host});

  test('a domain route wins over the plain one, whatever the order', () async {
    expect((await at('admin.example.com', '/')).body, 'admin');
    expect((await at('admin.example.com', '/same')).body, 'admin');
    expect((await at('other.test', '/same')).body, 'plain');
  });

  test('host matching ignores case, the port and the root dot', () async {
    expect((await at('ADMIN.Example.com:8080', '/')).body, 'admin');
    expect((await at('admin.example.com.', '/')).body, 'admin');
  });

  test('a literal host wins over a parameter registered first', () async {
    expect((await at('admin.first.test', '/who')).body, 'admin');
    expect((await at('acme.first.test', '/who')).body, 'tenant acme');
  });

  test('a Host header in any case, and IPv6', () async {
    final capital = await client.get(
      '/same',
      headers: {'Host': 'admin.example.com'},
    );
    expect(capital.body, 'admin');
    expect(
      Request.fake(path: '/', headers: {'host': '[::1]:8080'}).host,
      '::1',
    );
    expect(Request.fake(path: '/', headers: {'host': '[::1]'}).host, '::1');
  });

  test('a parameter comes from the host', () async {
    expect((await at('acme.example.org', '/')).body, 'site acme');
    final page = await at('acme.example.org', '/page/7');
    expect(page.jsonMap, {'site': 'acme', 'id': '7'});
    expect(page.jsonMap.keys.first, 'site', reason: 'before the path ones');
  });

  test('it holds inside nested groups', () async {
    expect((await at('acme.example.org', '/in/nested')).body, 'acme');
  });

  test('a parameter is one label', () async {
    expect((await at('a.b.example.org', '/page/7')).status, 404);
  });

  test('group constraints apply to it', () async {
    expect((await at('ACME1.example.org', '/page/7')).status, 404);
  });

  test('another host does not reach the route', () async {
    expect((await at('other.test', '/fluent')).status, 404);
    expect((await at('api.example.net', '/fluent')).body, 'fluent');
  });

  test('405 and OPTIONS look at the host', () async {
    final wrong = await client.post(
      '/same',
      headers: {'host': 'admin.example.com'},
    );
    expect(wrong.status, 405);
    expect(
      (await client.post('/fluent', headers: {'host': 'x.test'})).status,
      404,
    );
  });

  test('a model from the host scopes the one in the path', () async {
    expect((await at('one.exams.test', '/exams/10')).status, 200);
    expect((await at('one.exams.test', '/exams/20')).status, 404);
    expect((await at('nobody.exams.test', '/exams/10')).status, 404);
  });

  group('url generation', () {
    Router router() => app.container.make<Router>();

    test('a domain route is absolute, on its own host', () {
      expect(router().url('admin.home'), 'http://admin.example.com/');
      expect(
        router().url('site.page', params: {'site': 'acme', 'id': 7}),
        'http://acme.example.org/page/7',
      );
    });

    test('the scheme comes from the base URL', () {
      final r = router()..baseUrl = 'https://app.test';
      expect(r.url('admin.home'), 'https://admin.example.com/');
    });

    test('a signed URL works on its tenant, and on no other', () async {
      final signed = Uri.parse(
        router().signedUrl('export', params: {'org': 'one'}),
      );
      expect(signed.host, 'one.sign.test');
      final path = '${signed.path}?${signed.query}';
      expect((await at('one.sign.test', path)).body, 'exported');
      expect((await at('ONE.sign.test:8080', path)).body, 'exported');
      expect((await at('two.sign.test', path)).status, 403);
    });

    test('a plain signed URL does not depend on the host', () async {
      final signed = Uri.parse(
        router().signedUrl('plain-signed', absolute: false),
      );
      final path = '${signed.path}?${signed.query}';
      expect((await at('behind.a.proxy', path)).status, 200);
    });

    test('a missing parameter is named', () {
      expect(
        () => router().url('site.page', params: {'id': 7}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('[site]'),
          ),
        ),
      );
    });
  });

  group('DomainPattern', () {
    test('refuses what is no host', () {
      for (final pattern in ['a b.test', 'a*.test', '{a}{a}.test', 'x/y']) {
        expect(() => DomainPattern(pattern), throwsArgumentError);
      }
    });

    test('a dot is a dot', () {
      expect(DomainPattern('a.test').match('axtest'), isNull);
    });
  });
}
