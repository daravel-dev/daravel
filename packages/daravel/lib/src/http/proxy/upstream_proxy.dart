import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../foundation/url_redaction.dart';
import '../headers.dart';
import '../http_exceptions.dart';
import '../request.dart';
import '../response.dart';
import 'shadow_parity.dart';

/// The upstream's answer to a replay.
final class ShadowAnswer {
  /// The upstream's [status], [contentType], [body] and [headers].
  const ShadowAnswer(
    this.status,
    this.contentType,
    this.body, {
    this.headers = const <String, List<String>>{},
  });

  /// The response headers a client would get through the proxy (lower-cased
  /// names; hop-by-hop and stripped headers left out).
  final Map<String, List<String>> headers;

  /// The status code.
  final int status;

  /// The `Content-Type`, or null.
  final String? contentType;

  /// The body bytes.
  final List<int> body;
}

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
  /// A proxy to the server at the base URL [upstream]; [preserveHost]
  /// sends the client's `Host` instead of the upstream's.
  UpstreamProxy(
    this.upstream, {
    this.preserveHost = false,
    Iterable<String> stripResponseHeaders = const ['x-powered-by'],
    this.timeout = const Duration(seconds: 60),
    Duration? bodyIdleTimeout,
    Duration connectTimeout = const Duration(seconds: 5),
    int? maxConnectionsPerHost,
    HttpClient? client,
  }) : stripResponseHeaders = {
         for (final name in stripResponseHeaders) name.toLowerCase(),
       },
       bodyIdleTimeout = bodyIdleTimeout ?? timeout,
       _client =
           client ??
           (HttpClient()
             ..autoUncompress = false
             ..idleTimeout = const Duration(seconds: 15)
             ..connectionTimeout = connectTimeout
             ..maxConnectionsPerHost = maxConnectionsPerHost) {
    if (!upstream.hasScheme || upstream.host.isEmpty) {
      throw ArgumentError.value(
        redactUrlPassword('$upstream'),
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

  /// How long the upstream has to take the request and start answering
  /// (then 504, and the upstream connection is closed).
  final Duration timeout;

  /// How long the upstream may pause while streaming a response body (by
  /// default [timeout]); then the response to the client ends with an error
  /// and the upstream connection is closed.
  final Duration bodyIdleTimeout;

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
  ///
  /// The method is the one on the wire ([Request.originalMethod]), not a
  /// `_method` override: Laravel reads the override itself, and PHP parses
  /// a multipart body only for a `POST`.
  Future<Response> forward(Request request) async {
    final HttpClientResponse answer;
    final deadline = Stopwatch()..start();
    HttpClientRequest? outgoing;
    var answered = false;
    try {
      final sending = await _open(request, timeout);
      outgoing = sending;
      _copyRequestHeaders(request, sending.headers);
      // A body is announced by a length or by chunked encoding.
      final length = request.contentLength;
      final chunked = request.headers.first('transfer-encoding') != null;
      if (length != null) {
        sending.contentLength = length;
      } else if (chunked) {
        sending.headers.chunkedTransferEncoding = true;
      }
      // One deadline for sending the body and getting the answer.
      answer = await Future<HttpClientResponse>(() async {
        if ((length ?? 0) > 0 || (length == null && chunked)) {
          await sending.addStream(request.bodyStream());
        }
        return sending.close();
      }).timeout(_left(deadline));
      answered = true;
    } on TimeoutException {
      throw const HttpException(504, 'Gateway Timeout');
    } on IOException {
      throw const HttpException(502, 'Bad Gateway');
    } finally {
      // On any failure before the answer (a timeout, the network, or the
      // client's body refused as too large half way): without this the
      // upstream keeps the connection (and, behind PHP-FPM, a worker)
      // until its own timeout.
      if (!answered) {
        outgoing?.abort();
      }
    }
    final headers = Headers();
    final dropped = _connectionHeaders(
      answer.headers[HttpHeaders.connectionHeader],
    );
    answer.headers.forEach((name, values) {
      if (!hopByHop.contains(name) &&
          !stripResponseHeaders.contains(name) &&
          !dropped.contains(name)) {
        for (final value in values) {
          headers.add(name, value);
        }
      }
    });
    final length = answer.contentLength;
    final upstreamRequest = outgoing;
    // An upstream that stalls mid-body ends the response instead of
    // holding both connections open.
    final body = answer.timeout(
      bodyIdleTimeout,
      onTimeout: (sink) {
        upstreamRequest.abort();
        sink
          ..addError(
            TimeoutException(
              'The upstream stalled while sending the body.',
              bodyIdleTimeout,
            ),
          )
          ..close();
      },
    );
    return Response(
      status: answer.statusCode,
      headers: headers,
      body: StreamBody(body, contentLength: length >= 0 ? length : null),
    );
  }

  /// What is left of [timeout] since [started]; throws once it is spent.
  Duration _left(Stopwatch started) {
    final left = timeout - started.elapsed;
    if (left <= Duration.zero) {
      throw TimeoutException('The upstream did not answer in time.', timeout);
    }
    return left;
  }

  /// Opens a request to the upstream within [within]. A connection that
  /// opens after the timeout is closed at once instead of left behind.
  Future<HttpClientRequest> _open(Request request, Duration within) async {
    final opening = _client.openUrl(request.originalMethod, target(request));
    // ignore: close_sinks (returned; the caller closes or aborts it)
    final HttpClientRequest outgoing;
    try {
      outgoing = await opening.timeout(within);
    } on TimeoutException {
      unawaited(
        opening.then<void>((late) => late.abort(), onError: (Object _) {}),
      );
      rethrow;
    }
    return outgoing
      ..followRedirects = false
      ..persistentConnection = true;
  }

  /// The header names a `Connection` header lists: they describe this
  /// connection only, so they are not passed on (RFC 9110 §7.6.1).
  static Set<String> _connectionHeaders(Iterable<String>? values) => {
    for (final value in values ?? const <String>[])
      for (final name in value.split(','))
        if (name.trim().isNotEmpty) name.trim().toLowerCase(),
  };

  /// Replays [request] and reads the answer, or null when there is none to
  /// compare: the upstream failed, took too long, or sent over [maxBytes].
  /// In each of those cases the upstream connection is closed.
  Future<ShadowAnswer?> shadow(Request request, {required int maxBytes}) async {
    final deadline = Stopwatch()..start();
    HttpClientRequest? outgoing;
    var complete = false;
    try {
      final sending = await _open(request, timeout);
      outgoing = sending;
      _copyRequestHeaders(request, sending.headers);
      sending.headers
        ..set(ShadowParityRunner.header, '1')
        // A body to compare, not to decompress.
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      final answer = await sending.close().timeout(_left(deadline));
      final body = BytesBuilder(copy: false);
      await for (final chunk in answer.timeout(_left(deadline))) {
        body.add(chunk);
        if (body.length > maxBytes) {
          return null;
        }
      }
      complete = true;
      final headers = <String, List<String>>{};
      final dropped = _connectionHeaders(
        answer.headers[HttpHeaders.connectionHeader],
      );
      answer.headers.forEach((name, values) {
        if (!hopByHop.contains(name) &&
            !stripResponseHeaders.contains(name) &&
            !dropped.contains(name)) {
          headers[name] = List<String>.of(values);
        }
      });
      return ShadowAnswer(
        answer.statusCode,
        answer.headers.value(HttpHeaders.contentTypeHeader),
        body.takeBytes(),
        headers: headers,
      );
    } on TimeoutException {
      return null;
    } on IOException {
      return null;
    } finally {
      if (!complete) {
        outgoing?.abort();
      }
    }
  }

  void _copyRequestHeaders(Request request, HttpHeaders out) {
    final dropped = _connectionHeaders(request.headers.all('connection'));
    for (final MapEntry(key: name, value: values) in request.headers.entries) {
      if (name == 'host') {
        // As the client sent it: setting `host` alone would keep the
        // upstream's port (`example.test:9000`), and Laravel builds
        // `fullUrl()` and every URL it generates from this header. First,
        // so a `Connection: host` from the client cannot turn
        // [preserveHost] off.
        if (preserveHost && values.isNotEmpty) {
          out.set('host', values.first);
        }
        continue;
      }
      if (hopByHop.contains(name) ||
          dropped.contains(name) ||
          name.startsWith('x-forwarded-')) {
        continue;
      }
      for (final value in values) {
        out.add(name, value, preserveHeaderCase: true);
      }
    }
    // What the client sent through any proxy in front, then this hop; not
    // when `Connection` names it (it was for the hop before only).
    final chain = dropped.contains('x-forwarded-for')
        ? null
        : request.headers.first('x-forwarded-for');
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
