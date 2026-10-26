import 'message.dart';

/// Who and what a [Mailable] is about (Laravel's `Envelope`).
final class Envelope {
  const Envelope({
    required this.subject,
    this.from,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo = const [],
    this.headers = const {},
  });

  final String subject;

  /// The sender; `MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME` when null.
  final MailAddress? from;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final List<MailAddress> replyTo;
  final Map<String, String> headers;
}

/// The body of a [Mailable]: HTML, plain text or both (Laravel's
/// `Content`). Give both when you can; mail clients and spam filters
/// prefer a text alternative.
final class MailContent {
  const MailContent({this.html, this.text})
    : assert(html != null || text != null, 'Give html, text or both.');

  final String? html;
  final String? text;
}

/// An email (Laravel's `Mailable`):
///
/// ```dart
/// final class WelcomeMail extends Mailable {
///   WelcomeMail(this.user);
///   final User user;
///
///   @override
///   Envelope envelope() => const Envelope(subject: 'Welcome!');
///
///   @override
///   MailContent content() => MailContent(
///     html: '<h1>Hi ${escapeHtml(user.name)}</h1>',
///     text: 'Hi ${user.name}',
///   );
/// }
///
/// await Mail.to(user).send(WelcomeMail(user));
/// ```
abstract class Mailable {
  Mailable();

  Envelope envelope();

  MailContent content();

  List<MailAttachment> attachments() => const [];

  final List<MailAddress> _to = [];
  final List<MailAddress> _cc = [];
  final List<MailAddress> _bcc = [];

  /// Recipients added by `Mail.to(...)` (and [Envelope.to]).
  List<MailAddress> get to => List.unmodifiable([...envelope().to, ..._to]);
  List<MailAddress> get cc => List.unmodifiable([...envelope().cc, ..._cc]);
  List<MailAddress> get bcc => List.unmodifiable([...envelope().bcc, ..._bcc]);

  /// Adds recipients; used by `Mail.to(...).cc(...).bcc(...)`.
  void addRecipients({
    List<MailAddress> to = const [],
    List<MailAddress> cc = const [],
    List<MailAddress> bcc = const [],
  }) {
    _to.addAll(to);
    _cc.addAll(cc);
    _bcc.addAll(bcc);
  }

  bool hasTo(String email) => _has(to, email);
  bool hasCc(String email) => _has(cc, email);
  bool hasBcc(String email) => _has(bcc, email);

  static bool _has(List<MailAddress> list, String email) =>
      list.any((a) => a.email.toLowerCase() == email.toLowerCase());

  /// The message to send, [defaultFrom] when the envelope names no sender.
  MailMessage build({required MailAddress defaultFrom}) {
    final envelope = this.envelope();
    final content = this.content();
    return MailMessage(
      from: envelope.from ?? defaultFrom,
      to: to,
      cc: cc,
      bcc: bcc,
      replyTo: envelope.replyTo,
      subject: envelope.subject,
      html: content.html,
      text: content.text,
      attachments: attachments(),
      headers: envelope.headers,
    );
  }
}

/// [value] with `& < > " '` escaped, for text put into an HTML body.
String escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
