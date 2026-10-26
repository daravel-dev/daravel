import 'dart:async';

import '../logging/logger.dart';
import 'message.dart';

/// A sent message: its id and the raw MIME that went out.
final class SentMessage {
  const SentMessage(this.message, this.messageId, this.mime);

  final MailMessage message;

  /// Without angle brackets (`2f1c...@example.com`).
  final String messageId;
  final String mime;
}

/// Delivers rendered messages (`MAIL_MAILER`): `smtp`, `log`, `array`, or
/// one registered with `withMailTransport`.
abstract interface class MailTransport {
  /// Delivers [mime] (the rendered [message]) to its recipients.
  Future<void> send(MailMessage message, String mime);

  /// Releases connections; called when the application shuts down.
  Future<void> close();
}

/// Keeps messages in memory (`MAIL_MAILER=array`; the default in tests).
final class ArrayTransport implements MailTransport {
  final List<({MailMessage message, String mime})> messages = [];

  @override
  Future<void> send(MailMessage message, String mime) async {
    messages.add((message: message, mime: mime));
  }

  @override
  Future<void> close() async {}
}

/// Writes each message to the log instead of sending it
/// (`MAIL_MAILER=log`, Laravel's default).
final class LogTransport implements MailTransport {
  LogTransport(this._logger);

  final Logger _logger;

  @override
  Future<void> send(MailMessage message, String mime) async {
    _logger.debug('Mail "${message.subject}"', <String, Object?>{
      'to': [for (final a in message.recipients) a.email],
      'mime': mime,
    });
  }

  @override
  Future<void> close() async {}
}
