import 'dart:io';

import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Forwarded headers that a trusted proxy may supply.
enum ForwardedHeader {
  forwardedFor,
  forwardedProto,
  forwardedHost,
  forwardedPort,
}

/// An IPv4/IPv6 network in CIDR notation (`10.0.0.0/8`, `::1/128`) or a
/// single address.
final class Cidr {
  Cidr._(this._address, this.prefixLength);

  /// Parses `address[/prefix]`; throws [FormatException] on bad input.
  factory Cidr.parse(String value) {
    final slash = value.indexOf('/');
    final host = slash == -1 ? value : value.substring(0, slash);
    final address = InternetAddress.tryParse(host.trim());
    if (address == null) {
      throw FormatException('Invalid IP address or CIDR: "$value"');
    }
    final bits = address.rawAddress.length * 8;
    final prefix = slash == -1
        ? bits
        : int.tryParse(value.substring(slash + 1).trim());
    if (prefix == null || prefix < 0 || prefix > bits) {
      throw FormatException('Invalid CIDR prefix length: "$value"');
    }
    return Cidr._(address, prefix);
  }

  final InternetAddress _address;

  /// Number of leading bits that must match.
  final int prefixLength;

  /// Whether [ip] (textual) falls inside this network.
  bool contains(String ip) {
    final other = InternetAddress.tryParse(ip.trim());
    if (other == null) {
      return false;
    }
    final a = _address.rawAddress;
    final b = other.rawAddress;
    if (a.length != b.length) {
      return false;
    }
    var remaining = prefixLength;
    for (var i = 0; i < a.length && remaining > 0; i++) {
      final take = remaining >= 8 ? 8 : remaining;
      final mask = (0xff << (8 - take)) & 0xff;
      if ((a[i] & mask) != (b[i] & mask)) {
        return false;
      }
      remaining -= take;
    }
    return true;
  }

  @override
  String toString() => '${_address.address}/$prefixLength';
}

/// Applies `X-Forwarded-*` headers only when the TCP peer is a trusted
/// proxy (BLUEPRINT_V2 §2.3, §9.1). Without this middleware, or when the
/// peer is not trusted, forwarded headers are ignored and `request.ip` is
/// the socket address, which makes IP-based rate limiting unspoofable.
///
/// `X-Forwarded-For` is walked from the right: every trusted proxy is
/// skipped and the first untrusted address is the client.
final class TrustProxiesMiddleware implements Middleware {
  TrustProxiesMiddleware({
    List<String> proxies = const <String>[],
    this.trustAll = false,
    this.headers = const <ForwardedHeader>{
      ForwardedHeader.forwardedFor,
      ForwardedHeader.forwardedProto,
      ForwardedHeader.forwardedHost,
      ForwardedHeader.forwardedPort,
    },
  }) : _networks = proxies.map(Cidr.parse).toList(growable: false);

  /// Trust every peer (only behind a proxy that strips client headers).
  final bool trustAll;

  /// Which forwarded headers to honour.
  final Set<ForwardedHeader> headers;

  final List<Cidr> _networks;

  /// Whether [ip] is a trusted proxy.
  bool isTrusted(String ip) =>
      trustAll || _networks.any((network) => network.contains(ip));

  @override
  Future<Response> handle(Request request, Next next) {
    if (isTrusted(request.remoteAddress)) {
      _apply(request);
    }
    return next(request);
  }

  void _apply(Request request) {
    String? clientIp;
    List<String>? chain;
    if (headers.contains(ForwardedHeader.forwardedFor)) {
      final forwarded = request.headers
          .all('x-forwarded-for')
          .expand((value) => value.split(','))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      if (forwarded.isNotEmpty) {
        chain = <String>[...forwarded, request.remoteAddress];
        clientIp = forwarded.first;
        for (var i = forwarded.length - 1; i >= 0; i--) {
          if (!isTrusted(forwarded[i])) {
            clientIp = forwarded[i];
            break;
          }
        }
      }
    }
    String? scheme;
    if (headers.contains(ForwardedHeader.forwardedProto)) {
      final proto = request.headers
          .first('x-forwarded-proto')
          ?.split(',')
          .first
          .trim()
          .toLowerCase();
      if (proto == 'http' || proto == 'https') {
        scheme = proto;
      }
    }
    String? host;
    if (headers.contains(ForwardedHeader.forwardedHost)) {
      final value = request.headers
          .first('x-forwarded-host')
          ?.split(',')
          .first
          .trim();
      if (value != null &&
          value.isNotEmpty &&
          !value.contains(RegExp(r'[\s/\\]'))) {
        host = value;
      }
    }
    request.applyForwarded(
      ip: clientIp,
      ips: chain,
      scheme: scheme,
      host: host,
    );
  }
}
