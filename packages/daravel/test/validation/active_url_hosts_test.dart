import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/php_url.dart';
import 'package:test/test.dart';

/// `active_url` against Laravel 13: every URL of
/// `fixtures/laravel_active_url_hosts.json` went through Laravel's
/// `validateActiveUrl` with a resolver that records the name asked.
///
/// Laravel asks for `parse_url`'s host as written, plus a dot: no IDN
/// conversion, no percent-decoding (`bücher.de.`, `b%C3%BCcher.de.`,
/// `example.com..`). Such a name never has an address in DNS, so Daravel
/// fails it without asking; every other name it asks for, as Laravel does.
/// An IP address is not a name, and fails without asking too.
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_active_url_hosts.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(80)));
  });

  test('phpUrlHost is parse_url\'s host', () {
    for (final c in cases) {
      final host = c['host'];
      expect(
        phpUrlHost(c['url']! as String),
        host is String ? host : isNull,
        reason: jsonEncode(c['url']),
      );
    }
  });

  // A name DNS answers as written: labels of letters, digits, '-' and
  // '_', none empty, none over 63, not an IP address.
  bool answerable(String name) =>
      RegExp(r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$').hasMatch(name) &&
      name.split('.').every((label) => label.length <= 63) &&
      InternetAddress.tryParse(name) == null;

  test('active_url asks for the name Laravel asks for, or none', () async {
    var asked = 0;
    for (final c in cases) {
      final laravel = (c['asked']! as List<Object?>).cast<String>();
      final expected = [
        for (final name in laravel)
          if (answerable(name.substring(0, name.length - 1)))
            'A ${name.substring(0, name.length - 1).toLowerCase()}',
      ];
      final dns = _Recording();
      final errors = await Validator(
        {'v': c['url']},
        {'v': 'active_url'},
        container: Container()..instance<DnsResolver>(dns),
      ).run();
      expect(dns.lookups, expected, reason: jsonEncode(c['url']));
      expect(errors.isEmpty, expected.isNotEmpty, reason: jsonEncode(c));
      asked += expected.length;
    }
    // Most URLs of the golden are names DNS can answer.
    expect(asked, greaterThan(40));
  });
}

/// Every name has an address; the names asked are recorded.
final class _Recording implements DnsResolver {
  final List<String> lookups = [];

  @override
  Future<bool> hasAddress(String host) async {
    lookups.add('A $host');
    return true;
  }

  @override
  Future<List<String>?> mx(String host) async => null;
}
