import 'dart:async';
import 'dart:io';

import '../headers.dart';
import '../http_exceptions.dart';
import '../request.dart';
import '../response.dart';

/// Forwards requests Daravel has no route for to another server, usually
/// the Laravel application being migrated (the strangler fig pattern,
/// Blueprint #29): migrated routes answer from Daravel, the rest from
/// Laravel, behind one address, on one database.
///
/// Bodies stream both ways without being buffered. Redirects and
/// compressed bodies pass through as they are. Hop-by-hop headers are
/// dropped, and `X-Forwarded-For`, `-Proto`, `-Host` and `-Port` tell the
/// upstream who asked: trust Daravel in Laravel's `TrustProxies` so that
/// `$request->ip()` and generated URLs stay right.
final class UpstreamProxy {
  UpstreamProxy(
    this.upstream, {
    this.preserveHost = false,
    Iterable<String> stripResponseHeaders = const ['x-powered-by'],
    this.timeout = const Duration(seconds: 60),
    HttpClient? client,
  }) : stripResponseHeaders = {
         for (final name in stripResponseHeaders) name.toLowerCase(),
       },
       _client =
           client ??
           (HttpClient()
             ..autoUncompress = false
             ..idleTimeout = const Duration(seconds: 15)) {
    if (!upstream.hasScheme || upstream.host.isEmpty) {
      throw ArgumentError.value(
        '$upstream',
        'upstream',
        'needs http(s)://host',
      );
    }
  }

  /// The server requests are forwarded to; its path, if any, prefixes
  /// theirs (`http://legacy/app` + `/users` → `http://legacy/app/users`).
  final Uri upstream;

  /// Sends the client's `Host` to the upstream instead of the upstream's.
  final bool preserveHost;

  /// Response headers removed before they reach the client.
  final Set<String> stripResponseHeaders;

  /// How long the upstream has to start answering (then 504).
  final Duration timeout;

  final HttpClient _client;

  /// Headers that describe one connection, not the message (RFC 9110
  /// §7.6.1), plus the length the server sets again.
  static const Set<String> hopByHop = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'proxy-connection',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
  };

  /// The upstream URL of [request].
  Uri target(Request request) {
    final base = upstream.path.endsWith('/')
        ? upstream.path.substring(0, upstream.path.length - 1)
        : upstream.path;
    return upstream.replace(
      path: '$base${request.path}',
      query: request.uri.hasQuery ? request.uri.query : null,
    );
  }

  /// Forwards [request] and streams the answer back: 502 when the upstream
  /// cannot be reached, 504 when it does not answer within [timeout].
  Future<Response> forward(Request request) async {
    final HttpClientResponse answer;
    try {
      final outgoing = await _client
          .openUrl(request.method, target(request))
          .timeout(timeout);
      outgoing
        ..followRedirects = false
        ..persistentConnection = true;
      _copyRequestHeaders(request, outgoing.headers);
      // A body is announced by a length or by chunked encoding.
      final length = request.contentLength;
      final chunked = request.headers.first('transfer-encoding') != null;
      if (length != null) {
        outgoing.contentLength = length;
      } else if (chunked) {
        outgoing.headers.chunkedTransferEncoding = true;
      }
      if ((length ?? 0) > 0 || (length == null && chunked)) {
        await outgoing.addStream(request.bodyStream());
      }
      answer = await outgoing.close().timeout(timeout);
    } on TimeoutException {
      throw const HttpException(504, 'Gateway Timeout');
    } on IOException {
      throw const HttpException(502, 'Bad Gateway');
    }
    final headers = Headers();
    answer.headers.forEach((name, values) {
      if (!hopByHop.contains(name) && !stripResponseHeaders.contains(name)) {
        for (final value in values) {
          headers.add(name, value);
        }
      }
    });
    final length = answer.contentLength;
    return Response(
      status: answer.statusCode,
      headers: headers,
      body: StreamBody(answer, contentLength: length >= 0 ? length : null),
    );
  }

  void _copyRequestHeaders(Request request, HttpHeaders out) {
    for (final MapEntry(key: name, value: values) in request.headers.entries) {
      if (hopByHop.contains(name) || name.startsWith('x-forwarded-')) {
        continue;
      }
      if (name == 'host') {
        if (preserveHost) {
          out.host = request.uri.host;
          if (request.uri.hasPort) {
            out.port = request.uri.port;
          }
        }
        continue;
      }
      for (final value in values) {
        out.add(name, value, preserveHeaderCase: true);
      }
    }
    // What the client sent through any proxy in front, then this hop.
    final chain = request.headers.first('x-forwarded-for');
    final peer = request.remoteAddress;
    out
      ..set(
        'x-forwarded-for',
        chain == null || chain.isEmpty ? peer : '$chain, $peer',
      )
      ..set('x-forwarded-proto', request.scheme)
      ..set('x-forwarded-host', request.host);
    final port = request.uri.hasPort
        ? request.uri.port
        : (request.scheme == 'https' ? 443 : 80);
    out.set('x-forwarded-port', '$port');
  }

  /// Closes the connections to the upstream.
  void close() => _client.close(force: true);
}
