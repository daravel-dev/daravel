import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class WelcomeMail extends Mailable {
  WelcomeMail(this.name);
  final String name;

  @override
  Envelope envelope() => const Envelope(subject: 'Welcome!');

  @override
  MailContent content() =>
      MailContent(html: '<h1>Hi ${escapeHtml(name)}</h1>', text: 'Hi $name');
}

final class ReportMail extends Mailable {
  @override
  Envelope envelope() => Envelope(
    subject: 'Laporan bulanan — Oktober',
    from: MailAddress('reports@daravel.dev', 'Laporan Daravel'),
    replyTo: [MailAddress('ops@daravel.dev')],
    headers: const {'X-Report': 'monthly'},
  );

  @override
  MailContent content() => const MailContent(text: 'See attached.');

  @override
  List<MailAttachment> attachments() => [
    MailAttachment.bytes(utf8.encode('a,b\n1,2\n'), 'laporan-ü.csv'),
  ];
}

/// Decodes a quoted-printable body (for assertions).
String decodeQp(String encoded) {
  final bytes = <int>[];
  final text = encoded.replaceAll('=\r\n', '');
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '=' && i + 2 < text.length + 1) {
      bytes.add(int.parse(text.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      bytes.add(text.codeUnitAt(i));
    }
  }
  return utf8.decode(bytes);
}

void main() {
  final date = DateTime.utc(2026, 10, 26, 8, 30, 5);

  group('MailAddress', () {
    test('parses and renders names', () {
      final a = MailAddress.parse('Teo Prayoga <teo@daravel.dev>');
      expect((a.email, a.name), ('teo@daravel.dev', 'Teo Prayoga'));
      expect(a.header, 'Teo Prayoga <teo@daravel.dev>');
      expect(MailAddress('a@b.co', 'Doe, John').header, '"Doe, John" <a@b.co>');
      expect(MailAddress('a@b.co', 'Prayogá').header, startsWith('=?utf-8?B?'));
      expect(MailAddress.parse('"Doe, J" <a@b.co>').name, 'Doe, J');
    });

    test('rejects line breaks and non-addresses (header injection)', () {
      for (final bad in ['a@b.co\r\nBcc: x@y.z', 'no-at-sign', 'a b@c.d', '']) {
        expect(() => MailAddress(bad), throwsArgumentError, reason: bad);
      }
      expect(
        () => MailAddress('a@b.co', 'x\r\nBcc: y@z.co'),
        throwsArgumentError,
      );
    });
  });

  group('MailMessage.toMime', () {
    MailMessage message({
      String subject = 'Hello',
      Map<String, String> headers = const {},
    }) => MailMessage(
      from: MailAddress('noreply@daravel.dev', 'Daravel'),
      to: [MailAddress('teo@daravel.dev', 'Teo')],
      cc: [MailAddress('cc@daravel.dev')],
      bcc: [MailAddress('secret@daravel.dev')],
      subject: subject,
      html: '<p>Hi</p>',
      text: 'Hi',
      headers: headers,
    );

    test('headers, and text and html as alternatives', () {
      final mime = message().toMime(messageId: 'id1@daravel.dev', date: date);
      expect(mime, contains('From: Daravel <noreply@daravel.dev>\r\n'));
      expect(mime, contains('To: Teo <teo@daravel.dev>\r\n'));
      expect(mime, contains('Cc: cc@daravel.dev\r\n'));
      expect(mime, contains('Subject: Hello\r\n'));
      expect(mime, contains('Date: Mon, 26 Oct 2026 08:30:05 +0000\r\n'));
      expect(mime, contains('Message-ID: <id1@daravel.dev>\r\n'));
      expect(mime, contains('MIME-Version: 1.0\r\n'));
      expect(mime, contains('Content-Type: multipart/alternative; boundary="'));
      final textAt = mime.indexOf('Content-Type: text/plain; charset=utf-8');
      final htmlAt = mime.indexOf('Content-Type: text/html; charset=utf-8');
      // Text first: clients show the last alternative they understand.
      expect(textAt, greaterThan(0));
      expect(htmlAt, greaterThan(textAt));
      // Bcc recipients never appear in the headers.
      expect(mime, isNot(contains('secret@daravel.dev')));
      expect(message().recipients.map((a) => a.email), [
        'teo@daravel.dev',
        'cc@daravel.dev',
        'secret@daravel.dev',
      ]);
      // Only CRLF line endings.
      expect(mime.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test('non-ASCII subjects are RFC 2047 encoded words', () {
      final mime = message(subject: 'Selamat datang — 🎉 Daravel')
          .toMime(messageId: 'x@y', date: date);
      final subject = RegExp(
        r'Subject: (.*?)\r\n(?! )',
        dotAll: true,
      ).firstMatch(mime)![1]!;
      final decoded = RegExp(r'=\?utf-8\?B\?([^?]+)\?=')
          .allMatches(subject)
          .map((m) => utf8.decode(base64.decode(m[1]!)))
          .join();
      expect(decoded, 'Selamat datang — 🎉 Daravel');
      for (final line in subject.split('\r\n')) {
        expect(line.trim().length, lessThanOrEqualTo(75));
      }
    });

    test('header values with line breaks are refused', () {
      expect(() => message(subject: 'Hi\r\nBcc: x@y.co'), throwsArgumentError);
      expect(() => message(headers: {'X-Tag': 'a\nb'}), throwsArgumentError);
      expect(() => message(headers: {'Bad Name': 'v'}), throwsArgumentError);
    });

    test('attachments, sender, reply-to and custom headers of a mailable', () {
      final mail = ReportMail()
        ..addRecipients(to: [MailAddress('teo@daravel.dev')]);
      final mime = mail
          .build(defaultFrom: MailAddress('noreply@daravel.dev'))
          .toMime(messageId: 'r@d', date: date);
      expect(mime, contains('Content-Type: multipart/mixed; boundary="'));
      expect(mime, contains('Reply-To: ops@daravel.dev\r\n'));
      expect(mime, contains('X-Report: monthly\r\n'));
      expect(mime, contains('From: Laporan Daravel <reports@daravel.dev>\r\n'));
      expect(mime, contains("filename*=utf-8''laporan-%C3%BC.csv"));
      expect(mime, contains('Content-Type: text/csv; name="laporan-_.csv"'));
      expect(mime, contains(base64.encode(utf8.encode('a,b\n1,2\n'))));
    });
  });

  group('quoted-printable', () {
    test('round-trips text and keeps lines at most 76 characters', () {
      final text = '${'é' * 60} trailing \n= sign\n.dot line\n${'x' * 200}';
      final encoded = encodeQuotedPrintable(text);
      for (final line in encoded.split('\r\n')) {
        expect(line.length, lessThanOrEqualTo(76), reason: line);
        expect(line.startsWith('.'), isFalse, reason: 'SMTP end marker');
      }
      expect(decodeQp(encoded), text.replaceAll('\n', '\r\n'));
    });
  });

  group('MailConfig.fromEnv', () {
    MailConfig config(Map<String, String> env) =>
        MailConfig.fromEnv(Env.fromMap(env));

    test('Laravel 12 keys and defaults', () {
      final c = config(const {
        'APP_NAME': 'Shop',
        'APP_URL': 'https://shop.example.com',
        'MAIL_MAILER': 'smtp',
        'MAIL_HOST': 'smtp.example.com',
        'MAIL_PORT': '587',
        'MAIL_USERNAME': 'u',
        'MAIL_PASSWORD': 'p',
        'MAIL_FROM_ADDRESS': 'hello@shop.example.com',
      });
      expect(c.mailer, 'smtp');
      expect((c.host, c.port, c.username), ('smtp.example.com', 587, 'u'));
      expect(c.from.header, 'Shop <hello@shop.example.com>');
      expect(c.localDomain, 'shop.example.com');
      expect((c.implicitTls, c.requireTls), (false, false));
      expect(c.toMap()['password'], '********');
    });

    test('scheme, legacy encryption and port 465', () {
      expect(config(const {'MAIL_SCHEME': 'smtps'}).implicitTls, isTrue);
      expect(config(const {'MAIL_PORT': '465'}).implicitTls, isTrue);
      expect(config(const {'MAIL_ENCRYPTION': 'ssl'}).implicitTls, isTrue);
      final tls = config(const {'MAIL_ENCRYPTION': 'tls', 'MAIL_PORT': '587'});
      expect((tls.implicitTls, tls.requireTls), (false, true));
      expect(config(const {}).mailer, 'log');
      expect(config(const {'APP_ENV': 'testing'}).mailer, 'array');
    });
  });

  group('the Mail facade in an application', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'MAIL_FROM_ADDRESS': 'noreply@daravel.dev',
            'MAIL_FROM_NAME': 'Daravel',
          })
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    test('fake records mailables and their recipients', () async {
      final mail = Mail.fake();
      addTearDown(Mail.restore);
      await Mail.to('Teo <teo@daravel.dev>')
          .cc(['a@daravel.dev'])
          .send(WelcomeMail('Teo'));
      mail.assertSent<WelcomeMail>((m) => m.hasTo('teo@daravel.dev'));
      mail.assertSent<WelcomeMail>((m) => m.hasCc('a@daravel.dev'));
      mail.assertSentTimes<WelcomeMail>(1);
      mail.assertNotSent<ReportMail>();
      expect(() => mail.assertNothingSent(), throwsStateError);
      expect(
        () => mail.assertSent<WelcomeMail>((m) => m.hasTo('x@y.co')),
        throwsStateError,
      );
      expect(
        mail.messages.single.mime,
        contains('From: Daravel <noreply@daravel.dev>'),
      );
    });

    test('tests use the array transport', () async {
      final transport = Mail.mailer.transport as ArrayTransport;
      // Not queued: the sent message comes back.
      final sent = (await Mail.to('teo@daravel.dev').send(WelcomeMail('<b>')))!;
      expect(
        transport.messages.single.mime,
        contains('Message-ID: <${sent.messageId}>'),
      );
      // Escaped by the mailable; QP leaves these characters as they are.
      expect(transport.messages.single.mime, contains('&lt;b&gt;'));
    });

    test('a message without recipients is refused', () {
      expect(() => Mail.send(WelcomeMail('x')), throwsArgumentError);
    });
  });

  group('SmtpTransport', () {
    late ServerSocket server;
    late List<String> received;
    late String data;
    var auth = 'PLAIN LOGIN';
    String? failOn;
    var silent = false;

    setUp(() async {
      received = [];
      data = '';
      auth = 'PLAIN LOGIN';
      failOn = null;
      silent = false;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) {
        var inData = false;
        final buffer = StringBuffer();
        void reply(String line) => client.write('$line\r\n');
        if (silent) {
          return;
        }
        reply('220 fake.local ESMTP');
        client.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
          buffer.write(chunk);
          var text = buffer.toString();
          if (inData) {
            final end = text.indexOf('\r\n.\r\n');
            if (end < 0) {
              return;
            }
            data = text.substring(0, end + 2);
            buffer
              ..clear()
              ..write(text.substring(end + 5));
            inData = false;
            reply('250 2.0.0 queued');
            text = buffer.toString();
          }
          while (text.contains('\r\n')) {
            final line = text.substring(0, text.indexOf('\r\n'));
            text = text.substring(text.indexOf('\r\n') + 2);
            received.add(line);
            final verb = line.split(' ').first.toUpperCase();
            if (failOn != null && verb == failOn) {
              reply('550 5.1.1 mailbox unavailable');
            } else if (verb == 'EHLO') {
              reply('250-fake.local');
              reply('250-8BITMIME');
              reply('250 AUTH $auth');
            } else if (line.startsWith('AUTH PLAIN')) {
              reply('235 2.7.0 ok');
            } else if (line == 'AUTH LOGIN') {
              reply('334 VXNlcm5hbWU6');
            } else if (received.length >= 2 &&
                received[received.length - 2] == 'AUTH LOGIN') {
              reply('334 UGFzc3dvcmQ6');
            } else if (received.length >= 3 &&
                received[received.length - 3] == 'AUTH LOGIN') {
              reply('235 2.7.0 ok');
            } else if (verb == 'MAIL' || verb == 'RCPT') {
              reply('250 ok');
            } else if (verb == 'DATA') {
              reply('354 go ahead');
              inData = true;
              buffer
                ..clear()
                ..write(text);
              return;
            } else if (verb == 'QUIT') {
              reply('221 bye');
              client.destroy();
              return;
            } else {
              reply('500 unknown');
            }
          }
          buffer
            ..clear()
            ..write(text);
        });
      });
    });

    tearDown(() => server.close());

    MailConfig config({String? user, Duration? timeout}) => MailConfig(
      mailer: 'smtp',
      from: MailAddress('noreply@daravel.dev'),
      host: '127.0.0.1',
      port: server.port,
      username: user,
      password: user == null ? null : 's3cret',
      localDomain: 'app.daravel.dev',
      timeout: timeout ?? const Duration(seconds: 5),
    );

    final message = MailMessage(
      from: MailAddress('noreply@daravel.dev'),
      to: [MailAddress('teo@daravel.dev')],
      bcc: [MailAddress('audit@daravel.dev')],
      subject: 'Dots',
      text: '.leading dot\n..two\nend',
    );
    final mime = message.toMime(messageId: 'm@d', date: date);

    test('delivers to every recipient, with the MIME intact', () async {
      await SmtpTransport(config()).send(message, mime);
      expect(received.first, 'EHLO app.daravel.dev');
      expect(received, contains('MAIL FROM:<noreply@daravel.dev>'));
      expect(received, contains('RCPT TO:<teo@daravel.dev>'));
      expect(received, contains('RCPT TO:<audit@daravel.dev>'));
      expect(received.last, 'QUIT');
      // Undo dot-stuffing as a server does: the payload is the MIME.
      expect(data.replaceAll('\r\n..', '\r\n.'), mime);
      expect(received.where((l) => l.startsWith('AUTH')), isEmpty);
    });

    test('AUTH PLAIN and AUTH LOGIN', () async {
      await SmtpTransport(config(user: 'teo')).send(message, mime);
      final plain = received.firstWhere((l) => l.startsWith('AUTH PLAIN'));
      expect(
        utf8.decode(base64.decode(plain.substring('AUTH PLAIN '.length))),
        '\u0000teo\u0000s3cret',
      );
      received.clear();
      auth = 'LOGIN';
      await SmtpTransport(config(user: 'teo')).send(message, mime);
      final at = received.indexOf('AUTH LOGIN');
      expect(utf8.decode(base64.decode(received[at + 1])), 'teo');
      expect(utf8.decode(base64.decode(received[at + 2])), 's3cret');
    });

    test('a refused recipient is an SmtpException with its code', () async {
      failOn = 'RCPT';
      await expectLater(
        SmtpTransport(config()).send(message, mime),
        throwsA(
          isA<SmtpException>()
              .having((e) => e.code, 'code', 550)
              .having((e) => e.message, 'message', contains('RCPT')),
        ),
      );
    });

    test('a silent server times out', () async {
      silent = true;
      await expectLater(
        SmtpTransport(config(timeout: const Duration(milliseconds: 300)))
            .send(message, mime),
        throwsA(isA<SmtpException>()),
      );
    });

    test('STARTTLS is required when MAIL_ENCRYPTION=tls', () async {
      await expectLater(
        SmtpTransport(
          MailConfig(
            mailer: 'smtp',
            from: MailAddress('noreply@daravel.dev'),
            port: server.port,
            requireTls: true,
          ),
        ).send(message, mime),
        throwsA(
          isA<SmtpException>().having(
            (e) => e.message,
            'message',
            contains('STARTTLS'),
          ),
        ),
      );
    });
  });
}
