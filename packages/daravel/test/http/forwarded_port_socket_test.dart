@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Through a real socket: the port a request was made on, as Symfony's
/// `Request::getPort()` reads it. From a trusted proxy, `X-Forwarded-Port`
/// first, then the port of `X-Forwarded-Host`; else the port of `Host`;
/// else the default of the scheme. `url` carries a port only when it is not
/// that default, and `host` never carries one.
void main() {
  Future<ServerEngine> serve({List<String>? trustedProxies}) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router.get(
              '/p',
              (q) => {
                'scheme': q.scheme,
                'host': q.host,
                'port': q.port,
                'url': q.url,
              },
            );
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
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [MemoryHandler()]),
    );
    await engine.start();
    addTearDown(engine.stop);
    return engine;
  }

  Future<Map<String, Object?>> request(
    ServerEngine engine,
    List<String> headers,
  ) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    socket.add(
      latin1.encode(
        'GET /p HTTP/1.1\r\n'
        '${[...headers, 'Connection: close'].join('\r\n')}\r\n\r\n',
      ),
    );
    await socket.flush();
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    return jsonDecode(reply.substring(reply.indexOf('\r\n\r\n') + 4))
        as Map<String, Object?>;
  }

  const trusted = ['127.0.0.1'];

  test('X-Forwarded-Port from a trusted proxy: the port the client used '
      '(#327)', () async {
    final engine = await serve(trustedProxies: trusted);
    expect(
      await request(engine, [
        'Host: app.test:8000',
        'X-Forwarded-Proto: https',
        'X-Forwarded-Port: 443',
      ]),
      {
        'scheme': 'https',
        'host': 'app.test',
        'port': 443,
        'url': 'https://app.test/p',
      },
    );
  });

  test('the port of a trusted X-Forwarded-Host; host without it', () async {
    final engine = await serve(trustedProxies: trusted);
    expect(
      await request(engine, [
        'Host: internal:8000',
        'X-Forwarded-Proto: https',
        'X-Forwarded-Host: example.com:8443',
      ]),
      {
        'scheme': 'https',
        'host': 'example.com',
        'port': 8443,
        'url': 'https://example.com:8443/p',
      },
    );
  });

  test('X-Forwarded-Port wins over the port of X-Forwarded-Host', () async {
    final engine = await serve(trustedProxies: trusted);
    expect(
      await request(engine, [
        'Host: internal:8000',
        'X-Forwarded-Host: example.com:8443',
        'X-Forwarded-Port: 9443',
      ]),
      containsPair('port', 9443),
    );
  });

  test('a trusted X-Forwarded-Host without a port: the forwarded scheme\'s '
      'default, not the port of Host', () async {
    final engine = await serve(trustedProxies: trusted);
    expect(
      await request(engine, [
        'Host: internal:8000',
        'X-Forwarded-Proto: https',
        'X-Forwarded-Host: example.com',
      ]),
      {
        'scheme': 'https',
        'host': 'example.com',
        'port': 443,
        'url': 'https://example.com/p',
      },
    );
  });

  test(
    'only X-Forwarded-Proto: the port of Host, else the scheme default',
    () async {
      final engine = await serve(trustedProxies: trusted);
      expect(
        await request(engine, ['Host: app.test', 'X-Forwarded-Proto: https']),
        containsPair('url', 'https://app.test/p'),
      );
      expect(
        await request(engine, [
          'Host: app.test:8443',
          'X-Forwarded-Proto: https',
        ]),
        containsPair('url', 'https://app.test:8443/p'),
      );
    },
  );

  // Symfony 7.4 and 8.0 Request::getPort(): the trusted X-Forwarded-Port
  // becomes '0.0.0.0:0', its port '0' is falsy in PHP, and the scheme's
  // default is returned; the port of Host is not read. ('00' is not falsy
  // there and gives 0, a port no URL can carry; it is taken as 0 here.)
  test('X-Forwarded-Port 0: the default of the scheme, not the port of Host '
      'or of X-Forwarded-Host', () async {
    final engine = await serve(trustedProxies: trusted);
    for (final value in ['0', '00']) {
      expect(
        await request(engine, [
          'Host: app.test:8080',
          'X-Forwarded-Port: $value',
        ]),
        {
          'scheme': 'http',
          'host': 'app.test',
          'port': 80,
          'url': 'http://app.test/p',
        },
        reason: value,
      );
      expect(
        await request(engine, [
          'Host: internal:8000',
          'X-Forwarded-Proto: https',
          'X-Forwarded-Host: example.com:8443',
          'X-Forwarded-Port: $value',
        ]),
        {
          'scheme': 'https',
          'host': 'example.com',
          'port': 443,
          'url': 'https://example.com/p',
        },
        reason: value,
      );
    }
  });

  test('an X-Forwarded-Port that is no port is ignored', () async {
    final engine = await serve(trustedProxies: trusted);
    for (final value in ['abc', '70000', '-1', '8o', '']) {
      expect(
        await request(engine, [
          'Host: app.test:8080',
          'X-Forwarded-Port: $value',
        ]),
        containsPair('port', 8080),
        reason: value,
      );
    }
  });

  test('from a peer that is not trusted, and without the middleware, '
      'X-Forwarded-Port is ignored', () async {
    for (final engine in [
      await serve(trustedProxies: ['10.0.0.0/8']),
      await serve(),
    ]) {
      expect(
        await request(engine, ['Host: app.test:8080', 'X-Forwarded-Port: 443']),
        {
          'scheme': 'http',
          'host': 'app.test',
          'port': 8080,
          'url': 'http://app.test:8080/p',
        },
      );
    }
  });

  test('IPv6: host without brackets, url with them', () async {
    final engine = await serve(trustedProxies: trusted);
    expect(await request(engine, ['Host: [::1]:8080']), {
      'scheme': 'http',
      'host': '::1',
      'port': 8080,
      'url': 'http://[::1]:8080/p',
    });
    expect(
      await request(engine, [
        'Host: app.test',
        'X-Forwarded-Host: [2001:db8::1]:8443',
      ]),
      containsPair('url', 'http://[2001:db8::1]:8443/p'),
    );
  });
}
