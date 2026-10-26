import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email'],
  );
  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}

final class CreateUsers extends Migration {
  const CreateUsers();
  @override
  String get name => '2026_01_01_000000_create_users_table';
  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (t) {
    t.id();
    t.string('name');
    t.string('email');
    t.timestamps();
  });
  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

/// Queued because of the mixin: `Mail.to(...).send(...)` queues it.
final class ReceiptMail extends Mailable with ShouldQueue {
  ReceiptMail(this.total);
  final int total;

  @override
  String? get queue => 'mail';

  @override
  Envelope envelope() => Envelope(subject: 'Receipt $total');

  @override
  MailContent content() => MailContent(html: '<p>$total</p>', text: '$total');

  @override
  List<MailAttachment> attachments() => [
    MailAttachment.bytes(utf8.encode('total,$total\n'), 'receipt.csv'),
  ];
}

final class PlainMail extends Mailable {
  @override
  Envelope envelope() => const Envelope(subject: 'Plain');
  @override
  MailContent content() => const MailContent(text: 'plain');
}

final class Shipped extends Notification with ShouldQueue {
  const Shipped(this.order);
  final int order;

  @override
  List<String> via(Object notifiable) => ['mail', 'database', 'audit'];

  @override
  NotificationMail toMail(Object notifiable) =>
      NotificationMail().subject('Order $order shipped').line('On its way.');

  @override
  Map<String, Object?> toDatabase(Object notifiable) => {'order': order};
}

/// Not queueable: a queued notification still sends on it right away.
final class AuditChannel implements NotificationChannel {
  final List<String> sent = [];
  @override
  Future<void> send(Object n, Notification notification, String id) async =>
      sent.add(id);
}

void main() {
  late Application app;
  late User teo;
  late AuditChannel audit;

  setUp(() async {
    audit = AuditChannel();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'database',
          'MAIL_FROM_ADDRESS': 'shop@shop.test',
        })
        .withMigrations(const [
          CreateUsers(),
          CreateJobsTable(),
          CreateNotificationsTable(),
        ])
        .withNotificationChannel('audit', audit)
        .create();
    await app.boot();
    await app.container.make<Migrator>().run();
    teo = await User.definition.query().create({
      'name': 'Teo',
      'email': 'teo@shop.test',
    });
  });

  tearDown(() => app.shutdown());

  ArrayTransport transport() => Mail.mailer.transport as ArrayTransport;

  Future<void> work({String queue = 'default'}) =>
      QueueWorker(Queue.manager)
          .run(WorkerOptions(stopWhenEmpty: true, queues: [queue]));

  test(
    'a ShouldQueue mailable is queued as data and sent by a worker',
    () async {
      final sent = await Mail.to(teo)
          .bcc('audit@shop.test')
          .send(ReceiptMail(42));
      expect(sent, isNull, reason: 'queued, not sent');
      expect(transport().messages, isEmpty);

      // The payload is plain JSON: the framework job and the rendered message.
      final row = (await DB.table('jobs').get()).single;
      expect(row['queue'], 'mail');
      final payload = jsonDecode(row['payload']! as String) as Map;
      expect('$payload', contains(SendQueuedMail.name));

      await work(queue: 'mail');
      final message = transport().messages.single.message;
      expect(message.subject, 'Receipt 42');
      expect(message.to.single.header, 'Teo <teo@shop.test>');
      expect(message.bcc.single.email, 'audit@shop.test');
      expect(message.from.email, 'shop@shop.test');
      expect(utf8.decode(message.attachments.single.bytes), 'total,42\n');
      expect(transport().messages.single.mime, contains('receipt.csv'));
      expect(await DB.table('jobs').count(), 0);
    },
  );

  test('queue and later on any mailable', () async {
    Clock.freeze();
    addTearDown(Clock.restore);
    await Mail.to('a@shop.test').queue(PlainMail());
    await Mail.to('b@shop.test').later(const Duration(minutes: 5), PlainMail());
    await work();
    expect(transport().messages.map((m) => m.message.to.single.email), [
      'a@shop.test',
    ]);
    Clock.travel(const Duration(minutes: 6));
    await work();
    expect(transport().messages.map((m) => m.message.to.single.email), [
      'a@shop.test',
      'b@shop.test',
    ]);
  });

  test(
    'queued inside a transaction: pushed on commit, dropped on rollback',
    () async {
      await expectLater(
        DB.transaction(() async {
          await Mail.to('a@shop.test').queue(PlainMail());
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await DB.table('jobs').count(), 0);
      await DB.transaction(() async {
        await Mail.to('a@shop.test').queue(PlainMail());
        expect(await DB.table('jobs').count(), 0, reason: 'not before commit');
      });
      expect(await DB.table('jobs').count(), 1);
    },
  );

  test('Mail.fake tells queued from sent', () async {
    final mail = Mail.fake();
    addTearDown(Mail.restore);
    await Mail.to(teo).send(ReceiptMail(1));
    mail.assertQueued<ReceiptMail>((m) => m.hasTo('teo@shop.test'));
    mail.assertNothingSent();
    expect(
      () => mail.assertSent<ReceiptMail>(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('it was queued'),
        ),
      ),
    );
    expect(mail.assertNothingOutgoing, throwsStateError);
    mail.assertNotQueued<PlainMail>();
    expect(
      await DB.table('jobs').count(),
      0,
      reason: 'the fake pushes nothing',
    );
  });

  test(
    'a ShouldQueue notification: mail and database go through the queue',
    () async {
      await teo.notify(const Shipped(7));
      // The non-queueable channel sent at once; the others wait for a worker.
      expect(audit.sent, hasLength(1));
      expect(transport().messages, isEmpty);
      expect(await DB.table('notifications').count(), 0);
      final names = [
        for (final row in await DB.table('jobs').get())
          (jsonDecode(row['payload']! as String) as Map)['job'] ??
              (jsonDecode(row['payload']! as String) as Map)['displayName'],
      ];
      expect(names, hasLength(2));

      await work();
      expect(transport().messages.single.message.subject, 'Order 7 shipped');
      final stored = (await teo.notifications()).single;
      expect(stored.data, {'order': 7});
      expect(stored.type, r'App\Notifications\Shipped');
      // The id was fixed when it was sent, the same one the audit channel got.
      expect(stored.id, audit.sent.single);
    },
  );

  test('Notifications.fake records queued notifications as sent', () async {
    final fake = Notifications.fake();
    addTearDown(Notifications.restore);
    await teo.notify(const Shipped(3));
    fake.assertSentTo<Shipped>(teo, (n, channels) => n.order == 3);
    expect(await DB.table('jobs').count(), 0);
    expect(audit.sent, isEmpty);
  });
}
