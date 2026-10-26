import '../database/orm/model.dart';
import '../foundation/container.dart';
import '../mail/mailable.dart';
import '../mail/mailer.dart';
import '../mail/message.dart';
import '../mail/transport.dart';
import '../notifications/notification_manager.dart';

/// Laravel's `Mail` facade:
///
/// ```dart
/// await Mail.to(user).send(WelcomeMail(user));
/// await Mail.to('ops@example.com').cc(['a@example.com']).send(Report());
///
/// final mail = Mail.fake();
/// // ...
/// mail.assertSent<WelcomeMail>((m) => m.hasTo('teo@example.com'));
/// ```
abstract final class Mail {
  static Mailer get mailer => Container.current.make<Mailer>();

  /// [recipients]: an address, a `Name <address>` string, a model with an
  /// `email` (and `name`) attribute, or a list of those.
  static PendingMail to(Object recipients) => mailer.to(addresses(recipients));

  /// Sends [mailable] to the recipients its envelope names.
  /// A [ShouldQueue] mailable is queued (and `null` returned).
  static Future<SentMessage?> send(Mailable mailable) => mailer.send(mailable);

  /// Queues [mailable] for the recipients its envelope names.
  static Future<void> queue(Mailable mailable, {String? queue}) =>
      mailer.queue(mailable, queue: queue);

  static Future<SentMessage> sendMessage(MailMessage message) =>
      mailer.sendMessage(message);

  /// Records messages instead of sending them; undone by [restore].
  static MailFake fake() => mailer.fake();

  static void restore() => mailer.restore();

  /// [recipients] with models read through their `email` and `name`.
  static List<MailAddress> addresses(Object? recipients) =>
      switch (recipients) {
        final Model model => [addressOf(model)],
        final Iterable<Object?> list => [
          for (final item in list) ...addresses(item),
        ],
        _ => Mailer.addresses(recipients),
      };

  /// The address of [model]: its `email` attribute, named by `name`.
  static MailAddress addressOf(Model model) => mailAddressOf(model);
}
