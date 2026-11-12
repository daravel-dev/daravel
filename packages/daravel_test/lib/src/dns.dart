import 'dart:io';

import 'package:daravel/daravel.dart';

/// A [DnsResolver] for tests, with no network: by default every valid host
/// name that is not an IP address has an A record and no MX, as Laravel's
/// `Validator::$fakeDnsLookups`. [noAddress] lists hosts without one, and
/// [mxTargets] gives hosts MX targets (`''` for a null MX). Bind it in the
/// container (`app.container.instance<DnsResolver>(fake)`), or pass it to a
/// `Validator` through its container.
final class FakeDnsResolver implements DnsResolver {
  /// A fake resolver.
  FakeDnsResolver({this.noAddress = const {}, this.mxTargets = const {}});

  /// Hosts without an A or AAAA record.
  final Set<String> noAddress;

  /// MX targets by host (`''` for a null MX); others have none.
  final Map<String, List<String>> mxTargets;

  /// Every lookup asked, in order (`A foo.com`, `MX foo.com`).
  final List<String> lookups = [];

  static final RegExp _hostname = RegExp(
    r'^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$',
    caseSensitive: false,
  );

  @override
  Future<bool> hasAddress(String host) async {
    lookups.add('A $host');
    return _hostname.hasMatch(host) &&
        InternetAddress.tryParse(host) == null &&
        !noAddress.contains(host);
  }

  @override
  Future<List<String>?> mx(String host) async {
    lookups.add('MX $host');
    return mxTargets[host] ?? const [];
  }
}
