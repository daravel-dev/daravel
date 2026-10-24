import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../foundation/clock.dart';
import '../headers.dart';
import '../http_exceptions.dart';
import '../middleware.dart';
import '../request.dart';
import '../response.dart';

/// Maintenance mode state in `storage/framework/down`, the file and JSON
/// shape Laravel's `php artisan down` writes (`dartisan down` / `up`).
final class MaintenanceMode {
  MaintenanceMode(this.path);

  /// The `down` file of the application at [basePath].
  factory MaintenanceMode.at(String basePath) =>
      MaintenanceMode(p.join(basePath, 'storage', 'framework', 'down'));

  final String path;

  bool get active => File(path).existsSync();

  /// The stored options, or `null` when the application is up.
  Map<String, Object?>? read() {
    try {
      final decoded = jsonDecode(File(path).readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
    } on PathNotFoundException {
      return null;
    } on FormatException {
      return <String, Object?>{};
    }
  }

  void activate({
    String? secret,
    int? retry,
    int? refresh,
    int status = 503,
    List<String> except = const <String>[],
  }) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'except': except,
          'redirect': null,
          'retry': retry,
          'refresh': refresh,
          'secret': secret,
          'status': status,
          'template': null,
        }),
      );
  }

  /// Returns whether the application was down.
  bool deactivate() {
    final file = File(path);
    if (!file.existsSync()) {
      return false;
    }
    file.deleteSync();
    return true;
  }
}

/// Answers 503 while the application is in maintenance mode, like Laravel's
/// `PreventRequestsDuringMaintenance`.
///
/// Health routes and [except] paths stay available. Visiting `/<secret>`
/// sets a `daravel_maintenance` bypass cookie (an HMAC of its expiry with
/// the secret, valid for 12 hours, as Laravel's) and redirects to `/`. The
/// `down` file is checked at most once a second, so requests stay cheap.
final class PreventRequestsDuringMaintenance implements Middleware {
  PreventRequestsDuringMaintenance(
    this.mode, {
    this._except = const <String>{},
    this.checkInterval = const Duration(seconds: 1),
  });

  final MaintenanceMode mode;
  final Set<String> _except;
  final Duration checkInterval;

  static const String cookieName = 'daravel_maintenance';

  final Stopwatch _sinceCheck = Stopwatch();
  Map<String, Object?>? _state;

  Map<String, Object?>? _current() {
    if (!_sinceCheck.isRunning || _sinceCheck.elapsed >= checkInterval) {
      _state = mode.read();
      _sinceCheck
        ..reset()
        ..start();
    }
    return _state;
  }

  @override
  Future<Response> handle(Request request, Next next) {
    final state = _current();
    if (state == null || _except.contains(request.path)) {
      return next(request);
    }
    final except = state['except'];
    if (except is List && except.contains(request.path)) {
      return next(request);
    }
    final secret = state['secret'];
    if (secret is String && secret.isNotEmpty) {
      if (request.path == '/$secret') {
        return Future.value(
          Response.redirect('/').withHeader('set-cookie', bypassCookie(secret)),
        );
      }
      if (hasValidBypassCookie(request, secret)) {
        return next(request);
      }
    }
    final retry = state['retry'];
    final refresh = state['refresh'];
    return Future.error(
      HttpException(
        state['status'] is int ? state['status']! as int : 503,
        'Service Unavailable',
        headers: <String, String>{
          if (retry is int) 'retry-after': '$retry',
          if (refresh is int) 'refresh': '$refresh',
        },
      ),
    );
  }

  /// A `Set-Cookie` value granting access for 12 hours.
  static String bypassCookie(String secret) {
    final expires = Clock.now().toUtc().add(const Duration(hours: 12));
    final timestamp = expires.millisecondsSinceEpoch ~/ 1000;
    final value = base64.encode(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'expires_at': timestamp,
          'mac': _mac(timestamp, secret),
        }),
      ),
    );
    return '$cookieName=$value; Expires=${HttpDate.format(expires)}; '
        'Path=/; HttpOnly; SameSite=Lax';
  }

  /// Whether [request] carries a bypass cookie made with [secret] that has
  /// not expired.
  static bool hasValidBypassCookie(Request request, String secret) {
    final raw = _cookie(request.headers, cookieName);
    if (raw == null) {
      return false;
    }
    try {
      final payload = jsonDecode(utf8.decode(base64.decode(raw)));
      if (payload is! Map<String, Object?>) {
        return false;
      }
      final expiresAt = payload['expires_at'];
      final mac = payload['mac'];
      if (expiresAt is! int || mac is! String) {
        return false;
      }
      return _equals(_mac(expiresAt, secret), mac) &&
          expiresAt >= Clock.now().millisecondsSinceEpoch ~/ 1000;
    } on FormatException {
      return false;
    }
  }

  static String _mac(int timestamp, String secret) => Hmac(
    sha256,
    utf8.encode(secret),
  ).convert(utf8.encode('$timestamp')).toString();

  static bool _equals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String? _cookie(Headers headers, String name) {
    for (final line in headers.all('cookie')) {
      for (final part in line.split(';')) {
        final separator = part.indexOf('=');
        if (separator > 0 && part.substring(0, separator).trim() == name) {
          return Uri.decodeComponent(part.substring(separator + 1).trim());
        }
      }
    }
    return null;
  }
}
