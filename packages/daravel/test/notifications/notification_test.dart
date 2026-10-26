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

final class InvoicePaid extends Notification {
  const InvoicePaid(this.total, {this.channels = const ['mail', 'database']});
  final int total;
  final List<String> channels;

  @override
  List<String> via(Object notifiable) => channels;

  @override
  NotificationMail toMail(Object notifiable) => NotificationMail()
      .line('We received your payment of $total.')
      .action('View invoice', 'https://shop.test/invoices/1?a=1&b=<2>')
      .line('Thank you!');

  @override
  Map<String, Object?> toDatabase(Object notifiable) => {
    'total': total,
    'url': '/invoices/1',
  };

  /// What the broadcast channel sends (no toBroadcast; Laravel then reads
  /// toArray, never toDatabase).
  @override
  Map<String, Object?> toArray(Object notifiable) => {'total': total};
}

final class Welcome extends Mailable {
  @override
  Envelope envelope() => const Envelope(subject: 'Custom welcome');
  @override
  MailContent content() => const MailContent(text: 'hi');
}

final class WelcomeNotification extends Notification {
  const WelcomeNotification();
  @override
  List<String> via(Object notifiable) => ['mail'];
  @override
  Mailable toMail(Object notifiable) => Welcome();
}

final class Ping extends Notification {
  const Ping();
  @override
  List<String> via(Object notifiable) => ['sms'];
}

final class SmsChannel implements NotificationChannel {
  final List<(Object, Notification, String)> sent = [];
  @override
  Future<void> send(Object n, Notification notification, String id) async =>
      sent.add((n, notification, id));
}

void main() {
  late Application app;
  late User teo;
  late User ana;
  late SmsChannel sms;

  // SQLite in memory, or PostgreSQL with DARAVEL_TEST_PG (its uuid and
  // bigint columns behave differently).
  final pg = Platform.environment['DARAVEL_TEST_PG'];

  /// Drops this suite's tables and ledger rows from a shared database.
  Future<void> reset() async {
    final schema = await Schema.builder();
    await schema.dropIfExists('notifications');
    await schema.dropIfExists('users');
    if (await schema.hasTable('migrations')) {
      await DB.table('migrations').whereIn('migration', [
        const CreateUsers().name,
        const CreateNotificationsTable().name,
      ]).delete();
    }
  }

  setUp(() async {
    sms = SmsChannel();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'APP_NAME': 'Shop',
          // This server broadcasts (Pusher protocol, as Reverb).
          'REVERB_APP_ID': '1',
          'REVERB_APP_KEY': 'key',
          'REVERB_APP_SECRET': 'secret',
          if (pg != null && pg.isNotEmpty) ...{
            'DB_CONNECTION': 'pgsql',
            'DB_URL': pg,
          } else
            'DB_DATABASE': ':memory:',
        })
        .withMigrations(const [CreateUsers(), CreateNotificationsTable()])
        .withNotificationChannel('sms', sms)
        .create();
    await app.boot();
    if (pg != null && pg.isNotEmpty) {
      await reset();
    }
    await app.container.make<Migrator>().run();
    teo = await User.definition.query().create({
      'name': 'Teo',
      'email': 'teo@shop.test',
    });
    ana = await User.definition.query().create({
      'name': 'Ana',
      'email': 'ana@shop.test',
    });
  });

  tearDown(() async {
    if (pg != null && pg.isNotEmpty) {
      await reset();
    }
    await app.shutdown();
  });

  test('mail and database channels, with Laravel-compatible rows', () async {
    final mail = Mail.fake();
    addTearDown(Mail.restore);
    Clock.freeze();
    addTearDown(Clock.restore);
    await teo.notify(const InvoicePaid(120));

    final message = mail.messages.single.message;
    expect(message.to.single.header, 'Teo <teo@shop.test>');
    // No subject set: Laravel's title of the class name.
    expect(message.subject, 'Invoice Paid');
    expect(message.text, contains('Hello!'));
    expect(message.text, contains('We received your payment of 120.'));
    expect(
      message.text,
      contains('View invoice: https://shop.test/invoices/1?a=1&b=<2>'),
    );
    expect(message.text, endsWith('Regards,\nShop'));
    // HTML: escaped, button after the first line, the rest after it.
    expect(
      message.html,
      contains('href="https://shop.test/invoices/1?a=1&amp;b=&lt;2&gt;"'),
    );
    expect(
      message.html!.indexOf('payment of 120'),
      lessThan(message.html!.indexOf('View invoice')),
    );
    expect(
      message.html!.indexOf('View invoice'),
      lessThan(message.html!.indexOf('Thank you!')),
    );

    final row = (await DB.table('notifications').get()).single;
    expect(
      row['id'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(row['type'], r'App\Notifications\InvoicePaid');
    expect(row['notifiable_type'], r'App\Models\User');
    expect(row['notifiable_id'], teo.key);
    expect(jsonDecode(row['data']! as String), {
      'total': 120,
      'url': '/invoices/1',
    });
    expect(row['read_at'], isNull);
    // Text on SQLite, a DateTime from PostgreSQL: the same instant.
    String stored(Object? value) =>
        value is DateTime ? formatDateTime(value) : '$value';
    expect(stored(row['created_at']), formatDateTime(Clock.now()));
    expect(row['updated_at'], row['created_at']);
  });

  test('every notifiable gets its own id', () async {
    await Notifications.send([
      teo,
      ana,
    ], const InvoicePaid(5, channels: ['database']));
    final rows = await DB.table('notifications').get();
    expect(rows, hasLength(2));
    expect(rows[0]['id'], isNot(rows[1]['id']));
    expect({for (final r in rows) r['notifiable_id']}, {teo.key, ana.key});
  });

  test('reading and marking stored notifications', () async {
    for (final total in [1, 2, 3]) {
      await teo.notify(InvoicePaid(total, channels: const ['database']));
    }
    await ana.notify(const InvoicePaid(9, channels: ['database']));
    expect(await Notifications.unreadCount(teo), 3);
    final all = await teo.notifications();
    expect(all, hasLength(3));
    expect(all.every((n) => !n.read && n.type.endsWith('InvoicePaid')), isTrue);
    expect(await Notifications.markAsRead(teo, [all.first.id]), 1);
    expect(await Notifications.unreadCount(teo), 2);
    expect((await teo.notifications(unreadOnly: true)), hasLength(2));
    expect(await Notifications.markAsRead(teo), 2);
    expect(await Notifications.unreadCount(teo), 0);
    // Ana's are hers.
    expect(await Notifications.unreadCount(ana), 1);
  });

  test('a row written by Laravel is read', () async {
    // Laravel's json_encode escapes slashes and non-ASCII.
    await DB.table('notifications').insert({
      'id': '9b2f0f5e-5f0a-4a3e-9d1e-0c6a1d2b3c4d',
      'type': r'App\Notifications\InvoicePaid',
      'notifiable_type': r'App\Models\User',
      'notifiable_id': teo.key,
      'data': r'{"url":"\/invoices\/1","note":"Terima kasih – ok"}',
      'read_at': null,
      'created_at': '2026-10-26 08:00:00',
      'updated_at': '2026-10-26 08:00:00',
    });
    final stored = (await teo.notifications()).single;
    expect(stored.data, {'url': '/invoices/1', 'note': 'Terima kasih – ok'});
    expect(stored.createdAt, DateTime.utc(2026, 10, 26, 8));
  });

  test('the table matches Laravel\'s notifications stub', () async {
    final columns = {
      for (final c in await (await Schema.builder()).getColumns(
        'notifications',
      ))
        c.name: c.nullable,
    };
    expect(columns, {
      'id': false,
      'type': false,
      'notifiable_type': false,
      'notifiable_id': false,
      'data': false,
      'read_at': true,
      'created_at': true,
      'updated_at': true,
    });
    // Created only when missing: a database Laravel migrated is fine.
    await const CreateNotificationsTable().up(await Schema.builder());
  });

  test(
    'a mailable from toMail, on-demand routes and custom channels',
    () async {
      final mail = Mail.fake();
      addTearDown(Mail.restore);
      await teo.notify(const WelcomeNotification());
      mail.assertSent<Welcome>((m) => m.hasTo('teo@shop.test'));

      await Notifications.route(
        'mail',
        'Ops <ops@shop.test>',
      ).notify(const InvoicePaid(1, channels: ['mail']));
      expect(mail.messages.last.message.to.single.email, 'ops@shop.test');
      await expectLater(
        Notifications.route(
          'mail',
          'ops@shop.test',
        ).notify(const InvoicePaid(1, channels: ['database'])),
        throwsStateError,
      );

      await teo.notify(const Ping());
      expect(sms.sent.single.$1, same(teo));
      await expectLater(
        teo.notify(const InvoicePaid(1, channels: ['pigeon'])),
        throwsStateError,
      );
    },
  );

  test('Notifications.fake and its assertions', () async {
    final fake = Notifications.fake();
    addTearDown(Notifications.restore);
    fake.assertNothingSent();
    await teo.notify(const InvoicePaid(7));
    await Notifications.route('mail', 'x@shop.test').notify(const Ping());
    // The same user loaded again is the same notifiable.
    final again = await User.definition.query().find(teo.key!);
    fake.assertSentTo<InvoicePaid>(
      again!,
      (n, channels) => n.total == 7 && channels.contains('database'),
    );
    fake.assertNotSentTo<InvoicePaid>(ana);
    fake.assertSentOnDemand<Ping>(
      (n, notifiable) => notifiable.routes['mail'] == 'x@shop.test',
    );
    fake.assertSentTimes<InvoicePaid>(1);
    expect(() => fake.assertSentTo<InvoicePaid>(ana), throwsStateError);
    expect(fake.assertNothingSent, throwsStateError);
    // Nothing was delivered.
    expect(await DB.table('notifications').count(), 0);
    expect(sms.sent, isEmpty);
  });

  test(
    'broadcast channel: Laravel\'s event, on the notifiable\'s channel',
    () async {
      // Laravel's PrivateChannel of the user, as Echo's
      // `.private('App.Models.User.1').notification()` listens.
      final subscription = await Broadcast.subscribe(
        'private-App.Models.User.${teo.key}',
      );
      final received = <String>[];
      subscription.messages.listen(received.add);
      await teo.notify(
        const InvoicePaid(5, channels: ['database', 'broadcast']),
      );
      await pumpEventQueue();

      // The Pusher frame each connection gets (after the excluded socket).
      final message = _frame(received.single);
      expect(
        message['event'],
        r'Illuminate\Notifications\Events\BroadcastNotificationCreated',
      );
      expect(message['channel'], 'private-App.Models.User.${teo.key}');
      // The same id as the database row, as in Laravel.
      final row = (await Notifications.of(teo)).single;
      // toArray, not toDatabase (which has the url): as Laravel. The data
      // is a JSON string in the frame, as Reverb sends it.
      expect(jsonDecode(message['data']! as String), {
        'total': 5,
        'id': row.id,
        'type': r'App\Notifications\InvoicePaid',
      });

      // A route instead of a model.
      final ops = await Broadcast.subscribe('ops');
      final opsMessages = <String>[];
      ops.messages.listen(opsMessages.add);
      await Notifications.route(
        'broadcast',
        'ops',
      ).notify(const InvoicePaid(9, channels: ['broadcast']));
      await pumpEventQueue();
      expect(
        jsonDecode(_frame(opsMessages.single)['data']! as String),
        containsPair('total', 9),
      );
      await subscription.cancel();
      await ops.cancel();
    },
  );
}

/// A Pusher frame from a broadcaster envelope (`<except>\n<frame>`).
Map<String, Object?> _frame(String envelope) =>
    jsonDecode(envelope.substring(envelope.indexOf('\n') + 1))
        as Map<String, Object?>;
