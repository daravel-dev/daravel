import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'config.dart';
import 'manager.dart';
import 'session.dart';

/// Starts the session for a request and saves it after the response
/// (Laravel's `StartSession`): the id comes from the session cookie
/// (decrypted by [EncryptCookiesMiddleware] when that runs first), the
/// attributes from the handler; the response gets the cookie back, the
/// previous URL is recorded for `GET` page requests, and 2 requests in 100
/// sweep expired sessions.
final class StartSessionMiddleware implements Middleware {
  const StartSessionMiddleware({this.lottery});

  /// The random source of the garbage-collection lottery (tests).
  final Random? lottery;

  @override
  Future<Response> handle(Request request, Next next) async {
    final manager = App.make<SessionManager>();
    final config = manager.config;
    final session = manager.session(request.cookie(config.cookie));
    await session.start();
    request.attributes[RequestSession.sessionAttribute] = session;
    Container.current.currentScope?.put<Session>(session);
    await _collectGarbage(manager, config);

    final response = await next(request);

    if (request.method == 'GET' &&
        request.route != null &&
        !_isAjax(request) &&
        request.header('purpose') != 'prefetch') {
      session.previousUrl = request.url;
    }
    await session.save(request: request);
    return response.withCookie(
      config.cookie,
      session.id,
      maxAge: config.expireOnClose ? null : config.lifetime,
      path: config.path,
      domain: config.domain,
      secure: config.secure,
      httpOnly: config.httpOnly,
      sameSite: config.sameSite,
      partitioned: config.partitioned,
    );
  }

  Future<void> _collectGarbage(
    SessionManager manager,
    SessionConfig config,
  ) async {
    final (hits, outOf) = config.lottery;
    final random = lottery ?? _shared;
    if (random.nextInt(outOf) + 1 <= hits) {
      await manager.handler.gc(config.lifetime);
    }
  }

  static final Random _shared = Random();

  static bool _isAjax(Request request) =>
      request.header('x-requested-with') == 'XMLHttpRequest';
}

/// Laravel's `CookieValuePrefix`: an encrypted cookie's clear text starts
/// with `hmac_sha1(name . 'v2', key)` in hex and `|`, so a cookie cannot
/// be moved to another name.
abstract final class CookieValuePrefix {
  static String create(String cookieName, List<int> key) =>
      '${Hmac(sha1, key).convert(utf8.encode('${cookieName}v2'))}|';

  /// The value without its 41-character prefix.
  static String remove(String value) =>
      value.length > 41 ? value.substring(41) : '';

  /// The value without its prefix when one of [keys] made it, else `null`.
  static String? validate(
    String cookieName,
    String value,
    Iterable<List<int>> keys,
  ) {
    for (final key in keys) {
      if (value.startsWith(create(cookieName, key))) {
        return remove(value);
      }
    }
    return null;
  }
}

/// Encrypts every cookie the response sets and decrypts the ones the
/// request carries (Laravel's `EncryptCookies`, with `Crypt` and
/// [CookieValuePrefix]), so a Laravel application with the same `APP_KEY`
/// reads and writes the same cookies. A cookie that does not decrypt, or
/// was made for another name, is dropped from the request. [except]
/// names cookies left in clear.
final class EncryptCookiesMiddleware implements Middleware {
  const EncryptCookiesMiddleware({this.except = const <String>[]});

  final List<String> except;

  @override
  Future<Response> handle(Request request, Next next) async {
    final encrypter = Crypt.encrypter;
    await _decrypt(request, encrypter);
    final response = await next(request);
    return _encrypt(response, encrypter);
  }

  Future<void> _decrypt(Request request, Encrypter encrypter) async {
    final cookies = <String, String>{};
    for (final MapEntry(key: name, :value) in request.cookies.entries) {
      if (except.contains(name)) {
        cookies[name] = value;
        continue;
      }
      try {
        final clear = await encrypter.decryptString(value);
        final valid = CookieValuePrefix.validate(name, clear, encrypter.keys);
        if (valid != null) {
          cookies[name] = valid;
        }
      } on DecryptException {
        // Not ours (or tampered with): dropped, as Laravel sets it to null.
      }
    }
    request.replaceCookies(cookies);
  }

  Future<Response> _encrypt(Response response, Encrypter encrypter) async {
    final lines = response.headers.all('set-cookie');
    if (lines.isEmpty) {
      return response;
    }
    final encrypted = <String>[];
    for (final line in lines) {
      final separator = line.indexOf('=');
      final end = line.indexOf(';');
      if (separator <= 0) {
        encrypted.add(line);
        continue;
      }
      final name = line.substring(0, separator);
      final rawValue = end == -1
          ? line.substring(separator + 1)
          : line.substring(separator + 1, end);
      final attributes = end == -1 ? '' : line.substring(end);
      if (except.contains(name) || rawValue == 'deleted') {
        encrypted.add(line);
        continue;
      }
      final value = Uri.decodeComponent(rawValue);
      final cipher = await encrypter.encryptString(
        CookieValuePrefix.create(name, encrypter.key) + value,
      );
      encrypted.add('$name=${phpRawUrlEncode(cipher)}$attributes');
    }
    return response.withHeaderList('set-cookie', encrypted);
  }
}

/// Laravel's `TokenMismatchException`: rendered as `419` with
/// `CSRF token mismatch.`
final class TokenMismatchException extends HttpException {
  const TokenMismatchException() : super(419, 'CSRF token mismatch.');
}

/// Laravel's `VerifyCsrfToken`: a `POST`, `PUT`, `PATCH` or `DELETE`
/// request must carry the session's token as the `_token` input, the
/// `X-CSRF-TOKEN` header or the `X-XSRF-TOKEN` header (the encrypted
/// `XSRF-TOKEN` cookie, which this middleware sets on every response so
/// Axios and Angular send it back). [except] lists paths that skip the
/// check (`'webhooks/*'`). Needs [StartSessionMiddleware] before it.
final class VerifyCsrfTokenMiddleware implements Middleware {
  const VerifyCsrfTokenMiddleware({
    this.except = const <String>[],
    this.addHttpCookie = true,
  });

  /// Paths without a leading slash; a trailing `*` matches any suffix.
  final List<String> except;

  /// Whether to set the `XSRF-TOKEN` cookie.
  final bool addHttpCookie;

  @override
  Future<Response> handle(Request request, Next next) async {
    final session = request.sessionOrNull;
    if (session == null) {
      throw StateError(
        'VerifyCsrfTokenMiddleware needs StartSessionMiddleware before it.',
      );
    }
    if (_isReading(request) ||
        _isExcepted(request) ||
        await _tokensMatch(request, session)) {
      final response = await next(request);
      if (!addHttpCookie) {
        return response;
      }
      final config = App.make<SessionManager>().config;
      return response.withCookie(
        'XSRF-TOKEN',
        session.token ?? '',
        maxAge: config.lifetime,
        path: config.path,
        domain: config.domain,
        secure: config.secure,
        httpOnly: false,
        sameSite: config.sameSite,
        partitioned: config.partitioned,
      );
    }
    throw const TokenMismatchException();
  }

  static bool _isReading(Request request) =>
      const {'HEAD', 'GET', 'OPTIONS'}.contains(request.method);

  bool _isExcepted(Request request) {
    final path = request.path.replaceFirst(RegExp(r'^/+'), '');
    for (final pattern in except) {
      final clean = pattern.replaceFirst(RegExp(r'^/+'), '');
      if (clean.endsWith('*')) {
        final prefix = clean.substring(0, clean.length - 1);
        if (path.startsWith(prefix)) {
          return true;
        }
      } else if (path == clean) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _tokensMatch(Request request, Session session) async {
    final expected = session.token;
    final actual = await _tokenFromRequest(request);
    if (expected == null || actual == null || actual.isEmpty) {
      return false;
    }
    return _constantTimeEquals(expected, actual);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  Future<String?> _tokenFromRequest(Request request) async {
    final input = await request.input<Object?>('_token');
    if (input is String && input.isNotEmpty) {
      return input;
    }
    final header = request.header('x-csrf-token');
    if (header != null && header.isNotEmpty) {
      return header;
    }
    final xsrf = request.header('x-xsrf-token');
    if (xsrf != null && xsrf.isNotEmpty) {
      try {
        return CookieValuePrefix.remove(
          await Crypt.encrypter.decryptString(xsrf),
        );
      } on DecryptException {
        return '';
      }
    }
    return null;
  }
}
