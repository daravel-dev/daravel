@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Through a real socket (the test client never goes through `dart:io`):
/// a request's scheme, host and URL come from the request line, the `Host`
/// header and the listener. `X-Forwarded-Proto` and `X-Forwarded-Host`,
/// which any client can send, count only when `TrustProxiesMiddleware`
/// trusts the peer. `dart:io`'s `HttpRequest.requestedUri` reads both from
/// whoever sent them.
void main() {
  Future<(ServerEngine, MemoryHandler, Application)> serve({
    List<String>? trustedProxies,
  }) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        })
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router.get(
              '/echo',
              (q) => {
                'scheme': q.scheme,
                'host': q.host,
                'url': q.url,
                'secure': q.isSecure,
                'uri': '${q.uri}',
                'trusted': q.isFromTrustedProxy,
              },
            );
            router.get('/back', (q) => Response.back(q, fallback: '/home'));
            router.group((r) {
              r.get('/secret', (_) => 'admin only');
            }, domain: 'admin.example');
            router
                .get('/export', (_) => 'exported')
                .domain('{org}.sign.test')
                .name('export')
                .middleware(['signed']);
          },
        )
        .withMiddleware((middleware) {
          if (trustedProxies != null) {
            middleware.use([TrustProxiesMiddleware(proxies: trustedProxies)]);
          }
        })
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    final log = MemoryHandler();
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [log]),
    );
    await engine.start();
    addTearDown(engine.stop);
    return (engine, log, app);
  }

  Future<String> send(ServerEngine engine, String request) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.add(latin1.encode(request));
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    return reply;
  }

  String get(String target, List<String> headers) =>
      'GET $target HTTP/1.1\r\n${[...headers, 'Connection: close'].join('\r\n')}'
      '\r\n\r\n';

  Map<String, Object?> body(String reply) =>
      jsonDecode(reply.substring(reply.indexOf('\r\n\r\n') + 4))
          as Map<String, Object?>;

  const spoofed = [
    'X-Forwarded-Proto: https',
    'X-Forwarded-Host: evil.example',
  ];

  test('without a trusted proxy, X-Forwarded-* are ignored: scheme, host, '
      'URL and isSecure come from Host and the listener', () async {
    final (engine, log, _) = await serve();
    final reply = await send(
      engine,
      get('/echo?x=1', ['Host: app.example:8080', ...spoofed]),
    );
    expect(reply, startsWith('HTTP/1.1 200'));
    expect(body(reply), {
      'scheme': 'http',
      'host': 'app.example',
      'url': 'http://app.example:8080/echo',
      'secure': false,
      'uri': 'http://app.example:8080/echo?x=1',
      'trusted': false,
    });
    // Said once, for whoever runs a proxy and has not trusted it yet.
    await send(engine, get('/echo', ['Host: app.example', ...spoofed]));
    expect(
      log.records.where((r) => r.message.contains('X-Forwarded-Proto')),
      hasLength(1),
    );
  });

  test(
    'an absolute-form target gives its authority, never its scheme',
    () async {
      final (engine, _, _) = await serve();
      final reply = await send(
        engine,
        get('https://other.example/echo', ['Host: app.example']),
      );
      expect(body(reply), containsPair('scheme', 'http'));
      expect(body(reply), containsPair('host', 'other.example'));
      expect(body(reply), containsPair('secure', false));
    },
  );

  test('a peer that is not a trusted proxy: ignored', () async {
    final (engine, _, _) = await serve(trustedProxies: ['10.0.0.0/8']);
    final reply = await send(
      engine,
      get('/echo', ['Host: app.example', ...spoofed]),
    );
    expect(body(reply), containsPair('host', 'app.example'));
    expect(body(reply), containsPair('scheme', 'http'));
    expect(body(reply), containsPair('trusted', false));
  });

  test('a trusted proxy: applied', () async {
    final (engine, log, _) = await serve(trustedProxies: ['127.0.0.1']);
    final reply = await send(
      engine,
      get('/echo', ['Host: app.example', ...spoofed]),
    );
    expect(body(reply), containsPair('host', 'evil.example'));
    expect(body(reply), containsPair('scheme', 'https'));
    expect(body(reply), containsPair('url', 'https://evil.example/echo'));
    expect(body(reply), containsPair('secure', true));
    expect(body(reply), containsPair('trusted', true));
    expect(
      log.records.where((r) => r.message.contains('X-Forwarded-Proto')),
      isEmpty,
    );
  });

  test('X-Forwarded-Host does not reach a route of another domain', () async {
    final (engine, _, _) = await serve();
    final direct = await send(engine, get('/secret', ['Host: admin.example']));
    expect(direct, startsWith('HTTP/1.1 200'));
    final spoofedHost = await send(
      engine,
      get('/secret', ['Host: app.example', 'X-Forwarded-Host: admin.example']),
    );
    expect(spoofedHost, startsWith('HTTP/1.1 404'));
  });

  test('back() does not follow a foreign Referer that X-Forwarded-Host '
      'matches', () async {
    final (engine, _, _) = await serve();
    final reply = await send(
      engine,
      get('/back', [
        'Host: app.example',
        'X-Forwarded-Host: evil.example',
        'Referer: https://evil.example/phish',
      ]),
    );
    expect(reply, startsWith('HTTP/1.1 302'));
    expect(reply, isNot(contains('evil.example')));
    expect(reply.toLowerCase(), contains('location: /home'));
  });

  test("a URL signed for one tenant does not pass on another's host with "
      'X-Forwarded-Host', () async {
    final (engine, _, app) = await serve();
    final signed = Uri.parse(
      app.container.make<Router>().signedUrl('export', params: {'org': 'one'}),
    );
    final target = '${signed.path}?${signed.query}';
    expect(
      await send(engine, get(target, ['Host: one.sign.test'])),
      startsWith('HTTP/1.1 200'),
    );
    final spoofedHost = await send(
      engine,
      get(target, ['Host: two.sign.test', 'X-Forwarded-Host: one.sign.test']),
    );
    expect(spoofedHost, startsWith('HTTP/1.1 403'));
  });

  test('of two Host headers the last counts (dart:io keeps only it); '
      "HTTP/1.0 without Host gets the listener's address; IPv6 literals "
      'and ports are kept', () async {
    final (engine, _, _) = await serve();
    final twice = await send(
      engine,
      get('/echo', ['Host: a.example', 'Host: b.example']),
    );
    expect(body(twice), containsPair('host', 'b.example'));
    final old = await send(engine, 'GET /echo HTTP/1.0\r\n\r\n');
    expect(body(old), containsPair('host', '127.0.0.1'));
    expect(
      body(old),
      containsPair('uri', 'http://127.0.0.1:${engine.port}/echo'),
    );
    final v6 = await send(engine, get('/echo', ['Host: [::1]:8080']));
    expect(body(v6), containsPair('host', '::1'));
    expect(body(v6), containsPair('uri', 'http://[::1]:8080/echo'));
  });

  test('the socket and Application.handle (the test client\'s path) agree '
      'without forwarding headers', () async {
    final (engine, _, app) = await serve();
    final socket = body(
      await send(engine, get('/echo?x=1', ['Host: app.example:8080'])),
    );
    final response = await app.handle(
      Request.fake(
        path: '/echo',
        query: const {'x': '1'},
        headers: const {'host': 'app.example:8080'},
      ),
    );
    expect(jsonDecode(await response.bodyText()), socket);
  });
}
