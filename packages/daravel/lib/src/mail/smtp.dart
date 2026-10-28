import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mail_config.dart';
import 'message.dart';
import 'transport.dart';

/// An SMTP reply the transport did not expect.
final class SmtpException implements Exception {
  const SmtpException(this.message, [this.code]);

  final String message;

  /// The reply code (`535`, `550`, ...), when the server sent one.
  final int? code;

  @override
  String toString() =>
      'SmtpException: $message${code == null ? '' : ' ($code)'}';
}

/// Sends mail over SMTP (`MAIL_MAILER=smtp`), one connection per message:
/// EHLO, STARTTLS when offered (or TLS from the start with smtps), AUTH
/// PLAIN or LOGIN when credentials are set, then the message with its
/// lines dot-stuffed. Every step is bounded by [MailConfig.timeout].
final class SmtpTransport implements MailTransport {
  SmtpTransport(this.config, {this.securityContext, this.onBadCertificate});

  final MailConfig config;

  /// For servers with private certificates (tests, internal relays).
  final SecurityContext? securityContext;
  final bool Function(X509Certificate certificate)? onBadCertificate;

  @override
  Future<void> send(MailMessage message, String mime) async {
    final session = await _SmtpSession.open(this);
    try {
      await session.deliver(message, mime);
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> close() async {}
}

final class _SmtpSession {
  _SmtpSession(this._transport, this._socket) {
    _listen();
  }

  /// Connects; the session owns the socket and closes it in [close].
  static Future<_SmtpSession> open(SmtpTransport transport) async {
    final config = transport.config;
    return _SmtpSession(
      transport,
      config.implicitTls
          ? await SecureSocket.connect(
              config.host,
              config.port,
              context: transport.securityContext,
              onBadCertificate: transport.onBadCertificate,
              timeout: config.timeout,
            )
          : await Socket.connect(
              config.host,
              config.port,
              timeout: config.timeout,
            ),
    );
  }

  final SmtpTransport _transport;
  Socket _socket;
  StreamSubscription<List<int>>? _subscription;
  final StringBuffer _buffer = StringBuffer();
  final List<String> _lines = [];
  Completer<void>? _waiting;
  Object? _error;
  bool _done = false;

  MailConfig get _config => _transport.config;

  void _listen() {
    _subscription = _socket.listen(
      (bytes) {
        _buffer.write(latin1.decode(bytes));
        var text = _buffer.toString();
        var newline = text.indexOf('\n');
        while (newline >= 0) {
          _lines.add(text.substring(0, newline).replaceAll('\r', ''));
          text = text.substring(newline + 1);
          newline = text.indexOf('\n');
        }
        _buffer
          ..clear()
          ..write(text);
        _wake();
      },
      onError: (Object error) {
        _error = error;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  void _wake() {
    final waiting = _waiting;
    _waiting = null;
    waiting?.complete();
  }

  /// The next complete reply: its code and its lines' text.
  Future<({int code, List<String> lines})> _reply() async {
    final text = <String>[];
    while (true) {
      while (_lines.isEmpty) {
        if (_error != null) {
          throw SmtpException('Connection failed: $_error');
        }
        if (_done) {
          throw const SmtpException('The server closed the connection.');
        }
        final waiting = _waiting = Completer<void>();
        await waiting.future.timeout(
          _config.timeout,
          onTimeout: () => throw SmtpException(
            'No reply from ${_config.host}:${_config.port} within '
            '${_config.timeout.inSeconds}s.',
          ),
        );
      }
      final line = _lines.removeAt(0);
      final code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
      if (code == null) {
        throw SmtpException('Malformed reply: $line');
      }
      text.add(line.length > 4 ? line.substring(4) : '');
      // "250-..." continues, "250 ..." ends the reply.
      if (line.length < 4 || line[3] != '-') {
        return (code: code, lines: text);
      }
    }
  }

  Future<({int code, List<String> lines})> _expect(
    Set<int> codes, [
    String? command,
    String? label,
  ]) async {
    if (command != null) {
      _socket.write('$command\r\n');
    }
    final reply = await _reply();
    if (!codes.contains(reply.code)) {
      // The label names the step, never the line sent: the lines of AUTH
      // LOGIN are the base64 user and password, and this message reaches
      // failed_jobs and the log.
      final shown =
          label ??
          (command == null
              ? 'greeting'
              : command.startsWith('AUTH')
              ? 'AUTH'
              : command.split(' ').first);
      throw SmtpException('$shown: ${reply.lines.join(' ')}', reply.code);
    }
    return reply;
  }

  Future<Set<String>> _ehlo() async {
    final reply = await _expect({250}, 'EHLO ${_config.localDomain}');
    return {for (final line in reply.lines.skip(1)) line.toUpperCase()};
  }

  Future<void> deliver(MailMessage message, String mime) async {
    await _expect({220});
    var extensions = await _ehlo();
    final secure = _socket is SecureSocket;
    if (!secure && extensions.contains('STARTTLS')) {
      await _expect({220}, 'STARTTLS');
      await _subscription?.cancel();
      // Bounded like every other step: a server that answers 220 and then
      // stalls the handshake would hold the send (and its job) for ever.
      _socket = await SecureSocket.secure(
        _socket,
        host: _config.host,
        context: _transport.securityContext,
        onBadCertificate: _transport.onBadCertificate,
      ).timeout(_config.timeout);
      _lines.clear();
      _buffer.clear();
      _listen();
      extensions = await _ehlo();
    } else if (!secure && _config.requireTls) {
      throw const SmtpException(
        'MAIL_ENCRYPTION=tls but the server does not offer STARTTLS.',
      );
    }
    await _authenticate(extensions);
    await _expect({250}, 'MAIL FROM:<${message.from.email}>');
    for (final recipient in message.recipients) {
      await _expect({250, 251}, 'RCPT TO:<${recipient.email}>');
    }
    await _expect({354}, 'DATA');
    // Dot-stuffing: a line starting with "." gets another one.
    final body = mime.replaceAll('\r\n.', '\r\n..');
    _socket.write(body.startsWith('.') ? '.$body' : body);
    if (!body.endsWith('\r\n')) {
      _socket.write('\r\n');
    }
    await _expect({250}, '.');
  }

  Future<void> _authenticate(Set<String> extensions) async {
    final user = _config.username;
    if (user == null || user.isEmpty) {
      return;
    }
    final password = _config.password ?? '';
    final auth = extensions
        .where((e) => e.startsWith('AUTH'))
        .expand((e) => e.split(RegExp(r'[ =]')).skip(1))
        .toSet();
    if (auth.contains('PLAIN') || auth.isEmpty) {
      final token = base64.encode(utf8.encode('\u0000$user\u0000$password'));
      await _expect({235}, 'AUTH PLAIN $token');
    } else if (auth.contains('LOGIN')) {
      await _expect({334}, 'AUTH LOGIN');
      await _expect({334}, base64.encode(utf8.encode(user)), 'AUTH');
      await _expect({235}, base64.encode(utf8.encode(password)), 'AUTH');
    } else {
      throw SmtpException(
        'The server offers no supported AUTH method (${auth.join(', ')}).',
      );
    }
  }

  Future<void> close() async {
    try {
      if (!_done && _error == null) {
        _socket.write('QUIT\r\n');
        await _reply().timeout(const Duration(seconds: 2));
      }
    } on Object {
      // The message is already accepted; a missing QUIT reply is harmless.
    }
    await _subscription?.cancel();
    _socket.destroy();
  }
}
