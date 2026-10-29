import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Clock.restore);

  group('Request cookies', () {
    test('are parsed like PHP fills \$_COOKIE', () {
      final request = Request.fake(
        headers: const {
          'cookie': 'theme=dark; name=Jane+Doe; path=%2Fa%20b; theme=light',
        },
      );
      expect(request.cookies, {
        'theme': 'dark',
        'name': 'Jane Doe',
        'path': '/a b',
      });
      expect(request.cookie('theme'), 'dark');
      expect(request.cookie('missing'), isNull);
      expect(request.cookie('missing', 'x'), 'x');
      expect(request.hasCookie('name'), isTrue);
      expect(request.hasCookie('missing'), isFalse);
    });

    test('a malformed escape keeps the raw value', () {
      final request = Request.fake(headers: const {'cookie': 'a=%zz; b'});
      expect(request.cookies, {'a': '%zz'});
    });

    test('no Cookie header means no cookies', () {
      expect(Request.fake().cookies, isEmpty);
    });
  });

  group('Response.withCookie', () {
    test('writes what Laravel (Symfony Cookie) writes', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final response = Response.text('ok')
          .withCookie('session', 'a b/c;d', maxAge: const Duration(hours: 2))
          .withCookie(
            'pref',
            'x',
            domain: '.example.com',
            secure: true,
            httpOnly: false,
            sameSite: 'Strict',
          );
      expect(response.headers.all('set-cookie'), [
        'session=a%20b%2Fc%3Bd; expires=Thu, 29 Oct 2026 10:00:00 GMT; '
            'Max-Age=7200; path=/; httponly; samesite=lax',
        'pref=x; path=/; domain=.example.com; secure; samesite=strict',
      ]);
    });

    test('withoutCookie expires it as Cookie::forget does', () {
      Clock.fake(DateTime.utc(2026, 10, 29, 8));
      final response = Response.text('ok').withoutCookie('session');
      expect(
        response.headers.first('set-cookie'),
        'session=deleted; expires=Wed, 29 Oct 2025 07:59:59 GMT; Max-Age=0; '
        'path=/; httponly; samesite=lax',
      );
    });

    test('rejects invalid names and SameSite values', () {
      expect(
        () => Response.text('ok').withCookie('a b', 'x'),
        throwsArgumentError,
      );
      expect(
        () => Response.text('ok').withCookie('a', 'x', sameSite: 'loose'),
        throwsArgumentError,
      );
    });

    test('partitioned comes last, as Symfony 7.4 writes it', () {
      final response = Response.text(
        'ok',
      ).withCookie('a', 'b', secure: true, sameSite: 'none', partitioned: true);
      expect(
        response.headers.first('set-cookie'),
        'a=b; path=/; secure; httponly; samesite=none; partitioned',
      );
    });

    test('does not change the original response', () {
      final original = Response.text('ok');
      original.withCookie('a', 'b');
      expect(original.headers.all('set-cookie'), isEmpty);
    });
  });
}
