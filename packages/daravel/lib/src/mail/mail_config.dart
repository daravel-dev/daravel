import '../foundation/config.dart';
import '../foundation/env.dart';
import 'message.dart';

/// Mail configuration, from the keys of Laravel 12's `config/mail.php`.
final class MailConfig implements ConfigSection {
  const MailConfig({
    required this.mailer,
    required this.from,
    this.host = '127.0.0.1',
    this.port = 2525,
    this.username,
    this.password,
    this.implicitTls = false,
    this.requireTls = false,
    this.localDomain = 'localhost',
    this.timeout = const Duration(seconds: 30),
  });

  /// `MAIL_MAILER` (`smtp`, `log`, `array` or a registered transport):
  /// `log` by default as in Laravel, `array` with `APP_ENV=testing`.
  ///
  /// SMTP: `MAIL_SCHEME=smtps` (TLS from the start, port 465) or `smtp`
  /// (STARTTLS when the server offers it). Laravel 10's
  /// `MAIL_ENCRYPTION=ssl` / `tls` is read too; `tls` requires STARTTLS.
  factory MailConfig.fromEnv(Env env) {
    final port = env.integer('MAIL_PORT', 2525);
    final scheme = env.maybeString('MAIL_SCHEME')?.toLowerCase();
    final encryption = env.maybeString('MAIL_ENCRYPTION')?.toLowerCase();
    final implicit =
        scheme == 'smtps' ||
        (scheme == null &&
            (encryption == 'ssl' || (encryption == null && port == 465)));
    final appName = env.string('APP_NAME', 'Daravel');
    final appUrl = env.string('APP_URL', 'http://localhost');
    return MailConfig(
      mailer: env.string(
        'MAIL_MAILER',
        env.string('APP_ENV', 'production') == 'testing' ? 'array' : 'log',
      ),
      from: MailAddress(
        env.string('MAIL_FROM_ADDRESS', 'hello@example.com'),
        env.string('MAIL_FROM_NAME', appName),
      ),
      host: env.string('MAIL_HOST', '127.0.0.1'),
      port: port,
      username: env.maybeString('MAIL_USERNAME'),
      password: env.maybeString('MAIL_PASSWORD'),
      implicitTls: implicit,
      requireTls: !implicit && encryption == 'tls',
      localDomain:
          env.maybeString('MAIL_EHLO_DOMAIN') ??
          (Uri.tryParse(appUrl)?.host.isNotEmpty ?? false
              ? Uri.parse(appUrl).host
              : 'localhost'),
      timeout: env.duration('MAIL_TIMEOUT', const Duration(seconds: 30)),
    );
  }

  final String mailer;

  /// The default sender (`MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME`).
  final MailAddress from;
  final String host;
  final int port;
  final String? username;
  final String? password;

  /// TLS from the first byte (smtps).
  final bool implicitTls;

  /// Refuse to send without STARTTLS.
  final bool requireTls;

  /// The EHLO name (`MAIL_EHLO_DOMAIN`, else the host of `APP_URL`).
  final String localDomain;
  final Duration timeout;

  @override
  String get key => 'mail';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'mailer': mailer,
    'from': {'address': from.email, 'name': from.name},
    'host': host,
    'port': port,
    'username': username,
    'password': password == null ? null : '********',
    'scheme': implicitTls ? 'smtps' : 'smtp',
  };
}
