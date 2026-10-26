import 'dart:math';

import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';
import 'mail_config.dart';
import 'mailable.dart';
import 'theme.dart';
import 'message.dart';
import 'transport.dart';

/// Renders mailables and hands them to the configured [MailTransport]
/// (the `Mail` facade).
final class Mailer {
  Mailer(this.config, this.transport, {MailTheme? theme})
    : theme =
          theme ?? MailTheme(appName: config.appName, appUrl: config.appUrl);

  final MailConfig config;
  final MailTransport transport;

  /// The look of markdown and notification mail.
  final MailTheme theme;
  MailFake? _fake;

  /// Starts a message to [recipients] (addresses, `Name <address>`
  /// strings, or lists of them).
  PendingMail to(Object recipients) => PendingMail(this, addresses(recipients));

  /// Sends [mailable] to the recipients it was given, or queues it when it
  /// is [ShouldQueue] (then returns `null`).
  Future<SentMessage?> send(Mailable mailable) async {
    if (mailable is ShouldQueue) {
      final queued = mailable as ShouldQueue;
      await queue(
        mailable,
        queue: queued.queue,
        connection: queued.connection,
        delay: queued.delay,
      );
      return null;
    }
    final message = mailable.build(defaultFrom: config.from, theme: theme);
    _checkRecipients(message);
    final fake = _fake;
    if (fake != null) {
      final sent = _render(message);
      fake.sent.add((mailable: mailable, sent: sent));
      return sent;
    }
    return sendMessage(message);
  }

  /// Sends an already built [message].
  Future<SentMessage> sendMessage(MailMessage message) async {
    _checkRecipients(message);
    final sent = _render(message);
    final fake = _fake;
    if (fake != null) {
      fake.sent.add((mailable: null, sent: sent));
      return sent;
    }
    await transport.send(message, sent.mime);
    return sent;
  }

  /// Renders [mailable] now and puts it on the queue (Laravel's
  /// `Mail::queue`); a worker sends it. The content is fixed at this point,
  /// so later changes to the models it shows are not in the mail.
  Future<void> queue(
    Mailable mailable, {
    String? queue,
    String? connection,
    Duration? delay,
  }) async {
    final message = mailable.build(defaultFrom: config.from, theme: theme);
    _checkRecipients(message);
    final fake = _fake;
    if (fake != null) {
      fake.queued.add((mailable: mailable, message: message, delay: delay));
      return;
    }
    await Container.current.make<QueueManager>().push(
      SendQueuedMail(message),
      queue: queue,
      connection: connection,
      delay: delay,
    );
  }

  static void _checkRecipients(MailMessage message) {
    if (message.recipients.isEmpty) {
      throw ArgumentError(
        'The message "${message.subject}" has no recipients.',
      );
    }
  }

  SentMessage _render(MailMessage message) {
    final random = Random.secure();
    final id =
        '${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}'
        '@${message.from.domain}';
    return SentMessage(
      message,
      id,
      message.toMime(messageId: id, date: Clock.now()),
    );
  }

  /// Records messages instead of sending them (`Mail.fake()`).
  MailFake fake() => _fake = MailFake();

  void restore() => _fake = null;

  /// [recipients] as addresses: a [MailAddress], an address or
  /// `Name <address>` string, or an iterable of those.
  static List<MailAddress> addresses(Object? recipients) =>
      switch (recipients) {
        null => const [],
        final MailAddress address => [address],
        final String text => [MailAddress.parse(text)],
        final Iterable<Object?> list => [
          for (final item in list) ...addresses(item),
        ],
        _ => throw ArgumentError.value(
          recipients,
          'recipients',
          'Not an address, a string or a list of them',
        ),
      };
}

/// The job that sends a queued message (`daravel:mail`, registered by the
/// framework). Its payload is the rendered message.
final class SendQueuedMail extends Job {
  SendQueuedMail(this.message);

  static const String name = 'daravel:mail';

  static final JobDefinition definition = JobDefinition(
    name,
    (json) => SendQueuedMail(
      MailMessage.fromJson((json['message']! as Map).cast<String, Object?>()),
    ),
  );

  final MailMessage message;

  @override
  String get jobName => name;

  @override
  String get displayName => 'Mail "${message.subject}"';

  /// A busy or briefly unreachable SMTP server is retried.
  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [
    Duration(seconds: 10),
    Duration(minutes: 1),
  ];

  @override
  Map<String, Object?> toJson() => {'message': message.toJson()};

  @override
  Future<void> handle(JobContext ctx) async {
    await Container.current.make<Mailer>().sendMessage(message);
  }
}

/// `Mail.to(...).cc(...).bcc(...).send(mailable)`.
final class PendingMail {
  PendingMail(this._mailer, this._to);

  final Mailer _mailer;
  final List<MailAddress> _to;
  final List<MailAddress> _cc = [];
  final List<MailAddress> _bcc = [];

  PendingMail cc(Object recipients) {
    _cc.addAll(Mailer.addresses(recipients));
    return this;
  }

  PendingMail bcc(Object recipients) {
    _bcc.addAll(Mailer.addresses(recipients));
    return this;
  }

  /// Sends now; a [ShouldQueue] mailable is queued (and `null` returned).
  Future<SentMessage?> send(Mailable mailable) {
    _address(mailable);
    return _mailer.send(mailable);
  }

  /// Queues [mailable] (Laravel's `Mail::to()->queue()`).
  Future<void> queue(Mailable mailable, {String? queue, String? connection}) {
    _address(mailable);
    return _mailer.queue(mailable, queue: queue, connection: connection);
  }

  /// Queues [mailable] to be sent after [delay] (`Mail::to()->later()`).
  Future<void> later(Duration delay, Mailable mailable, {String? queue}) {
    _address(mailable);
    return _mailer.queue(mailable, queue: queue, delay: delay);
  }

  void _address(Mailable mailable) =>
      mailable.addRecipients(to: _to, cc: _cc, bcc: _bcc);
}

/// What `Mail.fake()` recorded, with Laravel's assertions.
final class MailFake {
  final List<({Mailable? mailable, SentMessage sent})> sent = [];
  final List<({Mailable mailable, MailMessage message, Duration? delay})>
  queued = [];

  /// The sent mailables of type [M] (matching [where]).
  List<M> sentMailables<M extends Mailable>([bool Function(M mail)? where]) => [
    for (final entry in sent)
      if (entry.mailable case final M mail when where == null || where(mail))
        mail,
  ];

  /// The queued mailables of type [M] (matching [where]).
  List<M> queuedMailables<M extends Mailable>([
    bool Function(M mail)? where,
  ]) => [
    for (final entry in queued)
      if (entry.mailable case final M mail when where == null || where(mail))
        mail,
  ];

  /// The rendered messages, mailables or not.
  List<SentMessage> get messages => [for (final e in sent) e.sent];

  void assertSent<M extends Mailable>([bool Function(M mail)? where]) {
    if (sentMailables<M>(where).isEmpty) {
      throw StateError(
        'Expected mailable [$M] to be sent; it was not'
        '${queuedMailables<M>(where).isEmpty ? '' : ' (it was queued)'}.',
      );
    }
  }

  void assertSentTimes<M extends Mailable>(int times) {
    final count = sentMailables<M>().length;
    if (count != times) {
      throw StateError('Expected [$M] sent $times time(s); it was $count.');
    }
  }

  void assertNotSent<M extends Mailable>([bool Function(M mail)? where]) {
    if (sentMailables<M>(where).isNotEmpty) {
      throw StateError('Expected mailable [$M] not to be sent; it was.');
    }
  }

  void assertNothingSent() {
    if (sent.isNotEmpty) {
      throw StateError(
        'Expected no mail; got ${sent.map((e) => '"${e.sent.message.subject}"').join(', ')}.',
      );
    }
  }

  void assertQueued<M extends Mailable>([bool Function(M mail)? where]) {
    if (queuedMailables<M>(where).isEmpty) {
      throw StateError(
        'Expected mailable [$M] to be queued; it was not'
        '${sentMailables<M>(where).isEmpty ? '' : ' (it was sent)'}.',
      );
    }
  }

  void assertNotQueued<M extends Mailable>([bool Function(M mail)? where]) {
    if (queuedMailables<M>(where).isNotEmpty) {
      throw StateError('Expected mailable [$M] not to be queued; it was.');
    }
  }

  void assertNothingQueued() {
    if (queued.isNotEmpty) {
      throw StateError(
        'Expected no queued mail; got ${queued.map((e) => '"${e.message.subject}"').join(', ')}.',
      );
    }
  }

  /// Neither sent nor queued (Laravel's `assertNothingOutgoing`).
  void assertNothingOutgoing() {
    assertNothingSent();
    assertNothingQueued();
  }
}
