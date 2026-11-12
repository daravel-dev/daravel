import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Socket and TLS failures of `SmtpTransport` reach the caller as an
/// `SmtpException` carrying the original error, never as a bare
/// `SocketException`, not even one escaping to the zone from an unobserved
/// write (CI run 42985015240, macOS: "Connection reset by peer").
void main() {
  final message = MailMessage(
    from: MailAddress('noreply@daravel.dev'),
    to: [MailAddress('ana@example.com')],
    subject: 'Hi',
    text: 'Hello',
  );
  const mime = 'Subject: Hi\r\n\r\nHello\r\n';

  MailConfig config(int port) => MailConfig(
    mailer: 'smtp',
    from: MailAddress('noreply@daravel.dev'),
    port: port,
    timeout: const Duration(seconds: 5),
  );

  /// Runs [send] and returns what it threw, plus every error that escaped
  /// to the zone instead.
  Future<(Object?, List<Object>)> run(Future<void> Function() send) async {
    final escaped = <Object>[];
    final thrown = Completer<Object?>();
    unawaited(
      runZonedGuarded(() async {
            try {
              await send();
              thrown.complete(null);
            } on Object catch (error) {
              thrown.complete(error);
            }
          }, (error, _) => escaped.add(error)) ??
          Future<void>.value(),
    );
    final result = await thrown.future;
    // Let a late done-future error surface.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return (result, escaped);
  }

  /// Closes [socket] with a TCP reset (SO_LINGER on, 0 s), the way a
  /// crashed or firewalled server drops a connection.
  void reset(Socket socket) {
    final linger = Platform.isWindows
        ? (Uint8List(4)..[0] = 1) // struct linger of two u_short
        : (Uint8List(8)..[0] = 1); // struct linger of two int
    final option = Platform.isLinux || Platform.isAndroid
        ? RawSocketOption(RawSocketOption.levelSocket, 13, linger)
        : RawSocketOption(RawSocketOption.levelSocket, 0x80, linger);
    socket
      ..setRawOption(option)
      ..destroy();
  }

  test(
    'a refused connection is an SmtpException with the SocketException',
    () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final (error, escaped) = await run(
        () => SmtpTransport(config(port)).send(message, mime),
      );
      expect(
        error,
        isA<SmtpException>()
            .having((e) => e.cause, 'cause', isA<SocketException>())
            .having((e) => e.message, 'message', contains('Cannot connect')),
      );
      expect(escaped, isEmpty);
    },
  );

  test('a server that resets the connection mid-dialogue', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((client) {
      client.write('220 fake.local ESMTP\r\n');
      // Reset as soon as the client speaks (EHLO).
      client.listen((_) => reset(client));
    });
    for (var i = 0; i < 10; i++) {
      final (error, escaped) = await run(
        () => SmtpTransport(config(server.port)).send(message, mime),
      );
      expect(error, isA<SmtpException>(), reason: 'run $i');
      expect(escaped, isEmpty, reason: 'run $i: nothing escapes to the zone');
    }
  });

  test(
    'a failed STARTTLS handshake is an SmtpException with the TLS error',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((client) {
        client.write('220 fake.local ESMTP\r\n');
        client.listen((bytes) {
          final line = String.fromCharCodes(bytes);
          if (line.startsWith('EHLO')) {
            client.write('250-fake.local\r\n250 STARTTLS\r\n');
          } else if (line.startsWith('STARTTLS')) {
            // Agree, then answer the handshake with plain text.
            client.write('220 go ahead\r\nthis is not TLS\r\n');
          }
        });
      });
      final (error, escaped) = await run(
        () => SmtpTransport(config(server.port)).send(message, mime),
      );
      expect(
        error,
        isA<SmtpException>()
            .having((e) => e.message, 'message', contains('STARTTLS handshake'))
            .having(
              (e) => e.cause,
              'cause',
              anyOf(isA<TlsException>(), isA<SocketException>()),
            ),
      );
      expect(escaped, isEmpty);
    },
  );
}
