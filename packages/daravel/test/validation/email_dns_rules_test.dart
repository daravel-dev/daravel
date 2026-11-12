import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/dns.dart' show maxDnsSuffixes;
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `email:rfc,strict,dns,spoof,filter,filter_unicode` and `active_url`
/// (W9.4a) as Laravel 13's `validateEmail` and `validateActiveUrl`, with
/// `DNSCheckValidation` from egulias/EmailValidator 4 and PHP's
/// FILTER_VALIDATE_EMAIL; no test touches the network.
void main() {
  late FakeDnsResolver dns;
  late Container container;

  setUp(() {
    dns = FakeDnsResolver(
      noAddress: {'no-a.com', 'mx-only.com', 'nullmx.com', 'gone.org'},
      mxTargets: {
        'mx-only.com': ['mail.mx-only.com'],
        'nullmx.com': [''],
      },
    );
    container = Container()..instance<DnsResolver>(dns);
  });

  Future<bool> valid(Object? value, Object rule) async => (await Validator(
    {'v': value},
    {'v': rule},
    container: container,
  ).run()).isEmpty;

  group('email modes', () {
    test('the DSL takes its modes, every one must pass', () async {
      expect(await valid('ana@example.com', 'email:rfc,dns'), isTrue);
      expect(await valid('ana@no-a.com', 'email:rfc,dns'), isFalse);
      expect(await valid('ana@no-a.com', 'email'), isTrue);
    });

    test(r'a value with \r or \n fails before any mode', () async {
      expect(await valid('ana@example.com\n', 'email:dns'), isFalse);
      expect(dns.lookups, isEmpty);
    });

    test('dns alone checks no syntax, as in Laravel', () async {
      expect(await valid('not an address@example.com', 'email:dns'), isTrue);
      expect(
        await valid('not an address@example.com', 'email:rfc,dns'),
        isFalse,
      );
    });

    test(
      'dns: reserved and single-label domains fail without a lookup',
      () async {
        for (final email in [
          'a@localhost',
          'a@shop.test',
          'a@x.example',
          'a@intranet.corp',
          'a@[127.0.0.1]',
        ]) {
          expect(await valid(email, 'email:dns'), isFalse, reason: email);
        }
        expect(dns.lookups, isEmpty);
      },
    );

    test('dns: MX without A passes; a null MX fails', () async {
      expect(await valid('a@mx-only.com', 'email:dns'), isTrue);
      expect(await valid('a@nullmx.com', 'email:dns'), isFalse);
    });

    test('dns: suffixes from the last two labels, a bounded walk', () async {
      // egulias asks gone.org first, then each longer suffix.
      expect(await valid('a@x.y.gone.org', 'email:dns'), isTrue);
      expect(dns.lookups.first, 'MX gone.org');
      dns.lookups.clear();
      final deep = '${List.filled(20, 'n').join('.')}.gone.org';
      await valid('a@$deep', 'email:dns');
      expect(
        dns.lookups.where((l) => l.startsWith('MX')),
        hasLength(lessThanOrEqualTo(maxDnsSuffixes)),
      );
    });

    test('dns: an IDN domain is looked up in punycode', () async {
      expect(await valid('a@bücher.de', 'email:dns'), isTrue);
      expect(dns.lookups.first, 'MX xn--bcher-kva.de');
    });

    test('filter: PHP FILTER_VALIDATE_EMAIL', () async {
      final cases = {
        'ana@example.com': true,
        '"ana.b"@example.com': true,
        // PHP's quoted-string class has no space: it needs a backslash.
        '"ana b"@example.com': false,
        r'"ana\ b"@example.com': true,
        'a@[127.0.0.1]': true,
        'a@[IPv6:2001:db8::1]': true,
        'a@localhost': false,
        'a..b@example.com': false,
        'ü@example.com': false,
        '${'a' * 65}@example.com': false,
        'a@${'b' * 64}.com': false,
      };
      for (final MapEntry(key: email, value: ok) in cases.entries) {
        expect(await valid(email, 'email:filter'), ok, reason: email);
      }
    });

    test(
      'filter_unicode allows letters of any script in the local part',
      () async {
        expect(await valid('ü@example.com', 'email:filter_unicode'), isTrue);
        expect(await valid('ü@exämple.com', 'email:filter_unicode'), isFalse);
      },
    );

    test('rfc is egulias\' parser; strict refuses its warnings', () async {
      // A single-label domain is RFC-valid with a TLD warning.
      expect(await valid('a@b', 'email:rfc'), isTrue);
      expect(await valid('a@b', 'email:strict'), isFalse);
      expect(await valid('"ana b"@example.com', 'email'), isTrue);
      expect(await valid('"ana b"@example.com', 'email:strict'), isFalse);
      expect(await valid('a..b@example.com', 'email'), isFalse);
      expect(await valid('ana@example.com', 'email:strict'), isTrue);
    });

    test('an unknown mode is rfc, as Laravel default arm', () async {
      expect(await valid('ana@example.com', 'email:dsn'), isTrue);
      expect(await valid('nope', 'email:dsn'), isFalse);
      expect(dns.lookups, isEmpty);
    });

    test('spoof is not supported and says so when the rules are built', () {
      // Not on each value checked: building the rules fails, before any
      // request data is read.
      expect(
        () => Validator({'v': 'ana@example.com'}, {'v': 'email:rfc,spoof'}),
        throwsA(isA<UnsupportedError>()),
      );
      expect(() => Rules.email(spoof: true), throwsUnsupportedError);
      expect(() => Rules.string().email(spoof: true), throwsUnsupportedError);
    });

    test('the builder takes the same modes', () async {
      expect(
        await valid('ana@no-a.com', Rules.email(rfc: true, dns: true)),
        isFalse,
      );
      expect(
        await valid('ü@example.com', Rules.email(filterUnicode: true)),
        isTrue,
      );
      expect(
        await valid('x@example.com', Rules.string().email(dns: true)),
        isTrue,
      );
    });
  });

  group('active_url', () {
    test('a host with an address record passes, one lookup', () async {
      expect(await valid('https://example.com/path?q=1', 'active_url'), isTrue);
      expect(dns.lookups, ['A example.com']);
    });

    test('a host without one fails', () async {
      expect(await valid('https://no-a.com', 'active_url'), isFalse);
    });

    test(
      'no host, an IP address, or a name DNS cannot carry: no lookup',
      () async {
        for (final url in [
          'example.com',
          'mailto:a@example.com',
          'http://127.0.0.1/',
          'http://[::1]:8080/',
          'http://${'a' * 64}.com/',
        ]) {
          expect(await valid(url, 'active_url'), isFalse, reason: url);
        }
        expect(await valid(42, 'active_url'), isFalse);
        expect(dns.lookups, isEmpty);
      },
    );

    test('without a resolver in the container, the system one is used', () {
      expect(Validator({'v': 'x'}, {'v': 'active_url'}).run(), completes);
    });

    test('the message is Laravel\'s', () async {
      final errors = await Validator(
        {'site': 'https://no-a.com'},
        {'site': Rules.activeUrl()},
        container: container,
      ).run();
      expect(errors['site'], ['The site field must be a valid URL.']);
    });
  });
}
