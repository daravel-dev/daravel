import 'message.dart';
import 'theme.dart';

/// Who and what a [Mailable] is about (Laravel's `Envelope`).
final class Envelope {
  /// Who a mailable goes to and its subject.
  const Envelope({
    required this.subject,
    this.from,
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.replyTo = const [],
    this.headers = const {},
  });

  /// The subject line.
  final String subject;

  /// The sender; `MAIL_FROM_ADDRESS` / `MAIL_FROM_NAME` when null.
  final MailAddress? from;

  /// The recipients.
  final List<MailAddress> to;

  /// The carbon copy recipients.
  final List<MailAddress> cc;

  /// The blind carbon copy recipients.
  final List<MailAddress> bcc;

  /// The addresses replies go to.
  final List<MailAddress> replyTo;

  /// Extra message headers.
  final Map<String, String> headers;
}

/// The body of a [Mailable] (Laravel's `Content`): HTML, plain text or
/// both, or [markdown] in the mail theme. Give a text alternative when you
/// can; mail clients and spam filters prefer messages that have one.
final class MailContent {
  /// The body: [html], [text], or [markdown] rendered with the mail theme.
  const MailContent({this.html, this.text, this.markdown, this.subcopy})
    : assert(
        html != null || text != null || markdown != null,
        'Give html, text, markdown or a combination.',
      );

  /// The HTML body.
  final String? html;

  /// The plain text body.
  final String? text;

  /// Laravel's `markdown:` view: rendered in the [MailTheme] (header,
  /// footer, inline styles) for the HTML part, and as text for the text
  /// part unless [text] is given. `<x-mail::button>` and
  /// `<x-mail::panel>` work as in Laravel.
  final String? markdown;

  /// Small print under a [markdown] body, above the footer.
  final String? subcopy;
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
  /// Mailables are plain classes; the data they show is in their fields.
  Mailable();

  /// The recipients, subject and headers.
  Envelope envelope();

  /// The body.
  MailContent content();

  /// Files attached to the message.
  List<MailAttachment> attachments() => const [];

  final List<MailAddress> _to = [];
  final List<MailAddress> _cc = [];
  final List<MailAddress> _bcc = [];

  /// Recipients added by `Mail.to(...)` (and [Envelope.to]).
  List<MailAddress> get to => List.unmodifiable([...envelope().to, ..._to]);

  /// Every carbon copy recipient, the envelope's and those added.
  List<MailAddress> get cc => List.unmodifiable([...envelope().cc, ..._cc]);

  /// Every blind carbon copy recipient, the envelope's and those added.
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

  /// Whether [email] is among the recipients.
  bool hasTo(String email) => _has(to, email);

  /// Whether [email] is among the carbon copy recipients.
  bool hasCc(String email) => _has(cc, email);

  /// Whether [email] is among the blind carbon copy recipients.
  bool hasBcc(String email) => _has(bcc, email);

  static bool _has(List<MailAddress> list, String email) =>
      list.any((a) => a.email.toLowerCase() == email.toLowerCase());

  /// The message to send, [defaultFrom] when the envelope names no sender.
  MailMessage build({required MailAddress defaultFrom, MailTheme? theme}) {
    final envelope = this.envelope();
    final content = this.content();
    final markdown = content.markdown;
    final style = theme ?? const MailTheme(appName: 'Daravel');
    return MailMessage(
      from: envelope.from ?? defaultFrom,
      to: to,
      cc: cc,
      bcc: bcc,
      replyTo: envelope.replyTo,
      subject: envelope.subject,
      html:
          content.html ??
          (markdown == null
              ? null
              : style.layout(style.render(markdown), subcopy: content.subcopy)),
      text:
          content.text ??
          (markdown == null
              ? null
              : markdownToText([markdown, ?content.subcopy].join('\n\n'))),
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
