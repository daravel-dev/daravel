import '../mail/mailable.dart';
import '../mail/message.dart';
import '../mail/theme.dart';

/// A notification (Laravel's `Notification`): [via] names the channels,
/// and each channel reads its own method.
///
/// ```dart
/// final class InvoicePaid extends Notification {
///   InvoicePaid(this.invoice);
///   final Invoice invoice;
///
///   @override
///   List<String> via(Object notifiable) => ['mail', 'database'];
///
///   @override
///   NotificationMail toMail(Object notifiable) => NotificationMail()
///       .subject('Invoice paid')
///       .line('We received your payment of ${invoice.total}.')
///       .action('View invoice', 'https://example.com/invoices/${invoice.id}');
///
///   @override
///   Map<String, Object?> toDatabase(Object notifiable) =>
///       {'invoice_id': invoice.id, 'total': invoice.total};
/// }
///
/// await user.notify(InvoicePaid(invoice));
/// ```
abstract class Notification {
  const Notification();

  /// The channels to send on: `mail`, `database`, or a registered one.
  List<String> via(Object notifiable);

  /// For the `mail` channel: a [NotificationMail] or a [Mailable].
  Object? toMail(Object notifiable) => null;

  /// For the `database` channel: the `data` column; [toArray] when null.
  Map<String, Object?>? toDatabase(Object notifiable) => null;

  Map<String, Object?> toArray(Object notifiable) => const {};

  /// The `type` column: Laravel stores the notification's class name, so
  /// the default is `App\Notifications\<ClassName>`.
  String databaseType(Object notifiable) => 'App\\Notifications\\$runtimeType';

  /// For the `broadcast` channel: the data sent; [toArray] when null
  /// (Laravel's `toBroadcast`).
  Map<String, Object?>? toBroadcast(Object notifiable) => null;

  /// The channels to broadcast on; empty for the notifiable's own
  /// (`App.Models.User.1`, Laravel's `receivesBroadcastNotificationsOn`).
  List<String> broadcastOn(Object notifiable) => const [];

  /// The broadcast event name: Laravel's
  /// `Illuminate\Notifications\Events\BroadcastNotificationCreated`.
  String broadcastAs() =>
      r'Illuminate\Notifications\Events\BroadcastNotificationCreated';

  /// The `type` sent with a broadcast: [databaseType] by default.
  String broadcastType(Object notifiable) => databaseType(notifiable);
}

/// The mail of a notification (Laravel's notification `MailMessage`): a
/// greeting, lines, an optional button and a salutation, rendered as HTML
/// and text.
final class NotificationMail {
  String? _subject;
  String? _greeting;
  String? _salutation;
  String _level = 'info';
  final List<String> _intro = [];
  final List<String> _outro = [];
  String? _actionText;
  String? _actionUrl;
  MailAddress? _from;
  final List<MailAddress> _replyTo = [];
  final List<MailAttachment> _attachments = [];

  NotificationMail subject(String subject) {
    _subject = subject;
    return this;
  }

  NotificationMail greeting(String greeting) {
    _greeting = greeting;
    return this;
  }

  /// A paragraph: before the button, or after it once [action] is set.
  NotificationMail line(String text) {
    (_actionText == null ? _intro : _outro).add(text);
    return this;
  }

  NotificationMail action(String text, String url) {
    _actionText = text;
    _actionUrl = url;
    return this;
  }

  /// Marks the mail as an error ("Whoops!" greeting, red button).
  NotificationMail error() {
    _level = 'error';
    return this;
  }

  NotificationMail success() {
    _level = 'success';
    return this;
  }

  NotificationMail salutation(String salutation) {
    _salutation = salutation;
    return this;
  }

  NotificationMail from(String email, [String? name]) {
    _from = MailAddress(email, name);
    return this;
  }

  NotificationMail replyTo(String email, [String? name]) {
    _replyTo.add(MailAddress(email, name));
    return this;
  }

  NotificationMail attach(MailAttachment attachment) {
    _attachments.add(attachment);
    return this;
  }

  /// A [Mailable] of this mail; [fallbackSubject] when none was set,
  /// [appName] signs the default salutation.
  Mailable toMailable({
    required String fallbackSubject,
    required String appName,
  }) => _NotificationMailable(this, fallbackSubject, appName);

  String _greetingText() =>
      _greeting ?? (_level == 'error' ? 'Whoops!' : 'Hello!');

  String _salutationText(String appName) => _salutation ?? 'Regards,\n$appName';

  String _text(String appName) {
    final out = StringBuffer('${_greetingText()}\n\n');
    for (final line in _intro) {
      out.write('$line\n\n');
    }
    if (_actionText != null) {
      out.write('$_actionText: $_actionUrl\n\n');
    }
    for (final line in _outro) {
      out.write('$line\n\n');
    }
    out.write(_salutationText(appName));
    return out.toString();
  }

  /// The body as Laravel's `notifications::email` markdown template
  /// writes it; user text is HTML-escaped, as Blade's `{{ }}` does.
  String _markdown(String appName) {
    final out = StringBuffer('# ${escapeHtml(_greetingText())}\n\n');
    for (final line in _intro) {
      out.write('${escapeHtml(line)}\n\n');
    }
    final url = _actionUrl;
    if (_actionText != null && url != null) {
      final color = switch (_level) {
        'success' || 'error' => _level,
        _ => 'primary',
      };
      out.write('${mailButton(_actionText!, url, color: color)}\n\n');
    }
    for (final line in _outro) {
      out.write('${escapeHtml(line)}\n\n');
    }
    out.write(escapeHtml(_salutationText(appName)).replaceAll('\n', '<br>\n'));
    return out.toString();
  }

  /// Laravel's subcopy under a button.
  String? _subcopy() {
    final url = _actionUrl;
    if (_actionText == null || url == null) {
      return null;
    }
    final display = url.replaceAll('mailto:', '').replaceAll('tel:', '');
    return "If you're having trouble clicking the \"${escapeHtml(_actionText!)}\" "
        'button, copy and paste the URL below\ninto your web browser: '
        '<span class="break-all">[${escapeHtml(display)}](${escapeHtml(url)})</span>';
  }
}

final class _NotificationMailable extends Mailable {
  _NotificationMailable(this._mail, this._fallbackSubject, this._appName);

  final NotificationMail _mail;
  final String _fallbackSubject;
  final String _appName;

  @override
  Envelope envelope() => Envelope(
    subject: _mail._subject ?? _fallbackSubject,
    from: _mail._from,
    replyTo: _mail._replyTo,
  );

  @override
  MailContent content() => MailContent(
    markdown: _mail._markdown(_appName),
    subcopy: _mail._subcopy(),
    text: _mail._text(_appName),
  );

  @override
  List<MailAttachment> attachments() => _mail._attachments;
}

/// `InvoicePaid` → `Invoice Paid` (Laravel's default notification subject).
String titleFromClass(String className) => className
    .replaceAllMapped(RegExp('(?<=[a-z0-9])([A-Z])'), (m) => ' ${m[1]}')
    .trim();
