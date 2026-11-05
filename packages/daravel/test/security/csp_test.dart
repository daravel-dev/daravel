@Tags(['security'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Content-Security-Policy (issue #138): `SecurityHeadersMiddleware` sends
/// one on HTML responses when configured, keywords are quoted, sources that
/// could add a directive are refused, and each request gets its own CSPRNG
/// nonce.
void main() {
  Future<Response> run(
    SecurityHeadersMiddleware middleware,
    Request request,
    Response Function(Request) handler,
  ) => middleware.handle(request, (req) async => handler(req));

  group('Csp builder', () {
    test('quotes keywords, hashes and nonces; hosts and schemes as given', () {
      final csp = Csp()
        ..defaultSrc(['self'])
        ..scriptSrc(['self', 'strict-dynamic', 'sha256-abc+/='])
        ..styleSrc(['SELF', "'unsafe-inline'"])
        ..imgSrc(['self', 'data:', 'https://cdn.example.com'])
        ..formAction(['self', 'https://pay.example.com'])
        ..frameAncestors(['none'])
        ..baseUri(['none'])
        ..upgradeInsecureRequests();
      expect(
        csp.render(),
        "default-src 'self'; script-src 'self' 'strict-dynamic' "
        "'sha256-abc+/='; style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data: https://cdn.example.com; "
        "form-action 'self' https://pay.example.com; "
        "frame-ancestors 'none'; base-uri 'none'; upgrade-insecure-requests",
      );
      expect(csp.usesNonce, isFalse);
      expect(csp.headerName, 'content-security-policy');
    });

    test('a directive given twice adds sources once', () {
      final csp = Csp()
        ..scriptSrc(['self'])
        ..scriptSrc(['self', 'https://a.example']);
      expect(csp.render(), "script-src 'self' https://a.example");
    });

    test('Csp.nonce becomes the given nonce, or is left out', () {
      final csp = Csp()..scriptSrc(['self', Csp.nonce]);
      expect(csp.usesNonce, isTrue);
      expect(csp.render(nonce: 'abc+/='), "script-src 'self' 'nonce-abc+/='");
      expect(csp.render(), "script-src 'self'");
      expect(() => csp.render(nonce: "x'; script-src *"), throwsArgumentError);
    });

    test('refuses sources and names that could add a directive', () {
      for (final source in [
        "self'; script-src *",
        'https://a.example; script-src *',
        'https://a.example script-src',
        'https://a.example,https://b.example',
        "'not-a-keyword'",
        'a\nb',
        '',
      ]) {
        expect(
          () => Csp().scriptSrc([source]),
          throwsArgumentError,
          reason: source,
        );
      }
      expect(() => Csp().directive('script-src; x'), throwsArgumentError);
      expect(() => Csp().directive('Script-Src'), throwsArgumentError);
    });

    test('strict preset and report-only', () {
      final csp = Csp.strict(reportOnly: true);
      expect(csp.headerName, 'content-security-policy-report-only');
      expect(
        csp.render(nonce: 'n0nce'),
        "default-src 'self'; script-src 'self' 'nonce-n0nce'; "
        "style-src 'self' 'nonce-n0nce'; img-src 'self' data:; "
        "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; "
        "form-action 'self'",
      );
    });
  });

  group('Request.cspNonce', () {
    test('16 CSPRNG bytes in base64, stable per request, new per request', () {
      final request = Request.fake();
      expect(request.hasCspNonce, isFalse);
      final nonce = request.cspNonce;
      expect(request.hasCspNonce, isTrue);
      expect(request.cspNonce, nonce);
      expect(base64.decode(nonce), hasLength(16));
      final seen = {for (var i = 0; i < 1000; i++) Request.fake().cspNonce};
      expect(seen, hasLength(1000));
    });
  });

  group('SecurityHeadersMiddleware(contentSecurityPolicy:)', () {
    test('no policy by default', () async {
      final response = await run(
        const SecurityHeadersMiddleware(),
        Request.fake(),
        (_) => Response.html('<p>x</p>'),
      );
      expect(response.headers.has('content-security-policy'), isFalse);
      expect(
        response.headers.has('content-security-policy-report-only'),
        isFalse,
      );
    });

    test('HTML responses only, with the nonce the page used', () async {
      final middleware = SecurityHeadersMiddleware(
        contentSecurityPolicy: Csp()
          ..defaultSrc(['self'])
          ..scriptSrc(['self', Csp.nonce]),
      );
      final request = Request.fake();
      final html = await run(
        middleware,
        request,
        (req) => Response.html('<script nonce="${req.cspNonce}">go()</script>'),
      );
      expect(
        html.headers['content-security-policy'],
        "default-src 'self'; script-src 'self' 'nonce-${request.cspNonce}'",
      );
      expect(await html.bodyText(), contains(request.cspNonce));

      final json = await run(
        middleware,
        Request.fake(),
        (_) => Response.json({'a': 1}),
      );
      expect(json.headers.has('content-security-policy'), isFalse);
    });

    test('two requests get two nonces', () async {
      final middleware = SecurityHeadersMiddleware(
        contentSecurityPolicy: Csp.strict(),
      );
      final first = await run(
        middleware,
        Request.fake(),
        (_) => Response.html(''),
      );
      final second = await run(
        middleware,
        Request.fake(),
        (_) => Response.html(''),
      );
      expect(
        first.headers['content-security-policy'],
        isNot(second.headers['content-security-policy']),
      );
    });

    test('a policy the handler set is kept; report-only header', () async {
      final own = await run(
        SecurityHeadersMiddleware(contentSecurityPolicy: Csp.strict()),
        Request.fake(),
        (_) => Response.html(
          '',
          headers: const {'content-security-policy': "default-src 'none'"},
        ),
      );
      expect(own.headers['content-security-policy'], "default-src 'none'");

      final reportOnly = await run(
        SecurityHeadersMiddleware(
          contentSecurityPolicy: Csp(reportOnly: true)..defaultSrc(['self']),
        ),
        Request.fake(),
        (_) => Response.html(''),
      );
      expect(reportOnly.headers.has('content-security-policy'), isFalse);
      expect(
        reportOnly.headers['content-security-policy-report-only'],
        "default-src 'self'",
      );
    });

    test(
      'through an application, the page and header share the nonce',
      () async {
        final base = Directory.systemTemp.createTempSync('daravel_csp');
        addTearDown(() => base.deleteSync(recursive: true));
        final app = Application.configure(basePath: base.path)
            .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
            .withRouting(
              web: (r) => r.get(
                '/',
                (request) => Response.html(
                  '<script nonce="${request.cspNonce}">start()</script>',
                ),
              ),
            )
            .withMiddleware(
              (m) => m.use([
                SecurityHeadersMiddleware(contentSecurityPolicy: Csp.strict()),
              ]),
            )
            .create();
        await app.boot();
        addTearDown(app.shutdown);
        final response = await app.handle(Request.fake());
        final body = await response.bodyText();
        final nonce = RegExp('nonce="([^"]+)"').firstMatch(body)![1]!;
        expect(
          response.headers['content-security-policy'],
          contains("script-src 'self' 'nonce-$nonce'"),
        );
      },
    );
  });
}
