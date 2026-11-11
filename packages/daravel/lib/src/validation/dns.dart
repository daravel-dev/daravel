import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'dns_wire.dart';

/// The DNS lookups of `active_url` and `email:dns`. Bind your own in the
/// container to change how names resolve; `FakeDnsResolver` (in
/// `daravel_test`) resolves without the network.
///
/// These rules make the server look up a name the user sent: each adds the
/// latency of a lookup to the request, so put the routes that use them
/// behind a rate limit.
abstract interface class DnsResolver {
  /// Whether [host] (ASCII, no trailing dot) has an A or AAAA record.
  Future<bool> hasAddress(String host);

  /// The MX targets of [host] (`''` for a null MX), or null when this
  /// resolver cannot tell (no MX support, a truncated answer, a timeout).
  Future<List<String>?> mx(String host);
}

/// The default [DnsResolver]: A/AAAA through the operating system
/// (`InternetAddress.lookup`, which runs off the event loop and reads
/// `/etc/hosts` as well, unlike PHP's `dns_get_record`), and MX through a
/// small UDP client asking the nameservers of `/etc/resolv.conf`.
///
/// Without a `resolv.conf` (Windows), [mx] answers null and the checks use
/// A/AAAA only: a domain with an MX and no address record then fails
/// `email:dns`, and a null MX is not seen.
///
/// Every lookup gives up after [timeout] in total (retries included) and
/// then counts as "no record": the rule fails, as Laravel's does when
/// `dns_get_record` fails.
final class SystemDnsResolver implements DnsResolver {
  /// A resolver with [timeout] per lookup; [nameservers] (address and port)
  /// replace those of `/etc/resolv.conf`.
  SystemDnsResolver({
    this.timeout = const Duration(seconds: 2),
    this.nameservers,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// The shared instance the rules use when the container binds none.
  static final SystemDnsResolver instance = SystemDnsResolver();

  /// How long one lookup may take, retries included.
  final Duration timeout;

  /// The nameservers asked for MX (address, port); null reads
  /// `/etc/resolv.conf`.
  final List<(InternetAddress, int)>? nameservers;
  final Random _random;

  @override
  Future<bool> hasAddress(String host) async {
    try {
      final found = await InternetAddress.lookup(host).timeout(timeout);
      return found.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<List<String>?> mx(String host) async {
    final servers = nameservers ?? _resolvConf();
    if (servers.isEmpty) {
      _debug('no nameserver to ask for MX; using A/AAAA only');
      return null;
    }
    final clock = Stopwatch()..start();
    // At most two servers, within one timeout for the whole lookup: each
    // waits for its share of what is left, so a silent first server leaves
    // time for the second.
    final asked = servers.take(2).toList();
    for (final (index, (address, port)) in asked.indexed) {
      final left = timeout - clock.elapsed;
      if (left <= Duration.zero) {
        break;
      }
      final answer = await _ask(
        address,
        port,
        host,
        left ~/ (asked.length - index),
      );
      switch (answer) {
        case MxRecords(:final targets):
          return targets;
        case MxUnknown(:final reason):
          _debug('MX of $host unknown ($reason); using A/AAAA only');
          return null;
        case MxMismatch() || null:
          continue;
      }
    }
    _debug('no MX answer for $host in $timeout; using A/AAAA only');
    return null;
  }

  /// One question to one server: the first datagram from [address]:[port]
  /// that answers it (same id, same question), or null on timeout.
  Future<MxAnswer?> _ask(
    InternetAddress address,
    int port,
    String host,
    Duration wait,
  ) async {
    final RawDatagramSocket socket;
    try {
      // Port 0: the system picks a random source port.
      socket = await RawDatagramSocket.bind(
        address.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
    } on SocketException {
      return null;
    }
    final id = _random.nextInt(0x10000);
    final done = Completer<MxAnswer?>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      // Every datagram waiting, so one forged packet cannot hide the answer.
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        if (done.isCompleted || d.address != address || d.port != port) {
          continue;
        }
        final answer = parseMxAnswer(d.data, id: id, name: host);
        if (answer is! MxMismatch) {
          done.complete(answer);
        }
      }
    });
    try {
      socket.send(buildMxQuery(id, host), address, port);
      return await done.future.timeout(wait, onTimeout: () => null);
    } on SocketException {
      return null;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  static List<(InternetAddress, int)> _resolvConf() {
    final file = File('/etc/resolv.conf');
    if (Platform.isWindows || !file.existsSync()) {
      return const [];
    }
    try {
      return [
        for (final line in file.readAsLinesSync())
          if (RegExp(r'^\s*nameserver\s+(\S+)').firstMatch(line)
              case final match?)
            if (InternetAddress.tryParse(match.group(1)!) case final ip?)
              (ip, 53),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static void _debug(String message) =>
      developer.log(message, name: 'daravel.validation.dns', level: 500);
}

/// The longest host name looked up (RFC 1035: 253 characters).
const int maxHostLength = 253;

/// [host] as the ASCII name DNS asks for, or null when it cannot be one:
/// lower case, a trailing dot dropped, each non-ASCII label in punycode
/// (`bücher` → `xn--bcher-kva`), labels of 1 to 63 characters, at most
/// [maxHostLength] in all. Not the full UTS #46 mapping of PHP's
/// `idn_to_ascii`: only lower-casing before punycode.
String? toAsciiHost(String host) {
  var name = host.toLowerCase();
  if (name.endsWith('.')) {
    name = name.substring(0, name.length - 1);
  }
  if (name.isEmpty) {
    return null;
  }
  final labels = <String>[];
  for (final label in name.split('.')) {
    final ascii = label.codeUnits.every((c) => c < 0x80)
        ? label
        : 'xn--${punycode(label)}';
    if (ascii.isEmpty || ascii.length > 63) {
      return null;
    }
    labels.add(ascii);
  }
  final result = labels.join('.');
  return result.length > maxHostLength ? null : result;
}

/// Whether [host] is an IP address (`127.0.0.1`, `::1`, `[::1]`) rather
/// than a name.
bool isIpLiteral(String host) {
  final bare = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  return InternetAddress.tryParse(bare) != null;
}

/// The punycode of [label] (RFC 3492 §6.3), without the `xn--` prefix.
String punycode(String label) {
  const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
  int adapt(int delta, int points, bool first) {
    var d = first ? delta ~/ damp : delta ~/ 2;
    d += d ~/ points;
    var k = 0;
    while (d > ((base - tMin) * tMax) ~/ 2) {
      d ~/= base - tMin;
      k += base;
    }
    return k + (base - tMin + 1) * d ~/ (d + skew);
  }

  String digit(int d) => String.fromCharCode(d < 26 ? d + 0x61 : d + 0x16);
  final input = label.runes.toList();
  final out = StringBuffer();
  for (final c in input) {
    if (c < 0x80) {
      out.writeCharCode(c);
    }
  }
  final basic = out.length;
  var handled = basic;
  if (basic > 0) {
    out.write('-');
  }
  var n = 0x80, delta = 0, bias = 72;
  while (handled < input.length) {
    final m = input.where((c) => c >= n).reduce(min);
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in input) {
      if (c < n) {
        delta++;
      }
      if (c == n) {
        var q = delta;
        for (var k = base; ; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) {
            break;
          }
          out.write(digit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        out.write(digit(q));
        bias = adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}

/// Top-level names egulias' `DNSCheckValidation` treats as local or
/// reserved: an address there fails `email:dns` without a lookup.
const Set<String> reservedTopLevelNames = {
  'test',
  'example',
  'invalid',
  'localhost',
  'local',
  'intranet',
  'internal',
  'private',
  'corp',
  'home',
  'lan',
};

/// The most domain suffixes `email:dns` looks up for one address. egulias
/// walks every suffix from the last two labels up; a name of many labels
/// would make one value cost dozens of lookups, so the walk stops here.
const int maxDnsSuffixes = 4;

/// `email:dns` as egulias' `DNSCheckValidation`: the domain after the last
/// `@` is not a single label or a reserved top-level name, and one of its
/// suffixes, from the last two labels up (at most [maxDnsSuffixes]), has
/// an MX, A or AAAA record and no null MX.
Future<bool> emailDomainResolves(String email, DnsResolver dns) async {
  final at = email.lastIndexOf('@');
  final domain = at == -1 ? email : email.substring(at + 1);
  final parts = domain.split('.');
  if (parts.length <= 1 || reservedTopLevelNames.contains(parts.last)) {
    return false;
  }
  if (isIpLiteral(domain)) {
    return false;
  }
  final ascii = toAsciiHost(domain);
  if (ascii == null) {
    return false;
  }
  final labels = ascii.split('.');
  var host = labels.removeLast();
  for (var tries = 0; labels.isNotEmpty && tries < maxDnsSuffixes; tries++) {
    host = '${labels.removeLast()}.$host';
    final targets = await dns.mx(host);
    if (targets != null && targets.any((t) => t.isEmpty || t == '.')) {
      continue; // A null MX: this name accepts no mail.
    }
    if ((targets?.isNotEmpty ?? false) || await dns.hasAddress(host)) {
      return true;
    }
  }
  return false;
}
