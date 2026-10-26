import 'dart:async';
import 'dart:convert';

import '../database/database_manager.dart';
import '../database/orm/casts.dart';
import '../database/orm/keys.dart';
import '../database/orm/model.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../mail/mailable.dart';
import '../mail/mailer.dart';
import '../mail/message.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';
import 'notification.dart';

/// Delivers a notification on one channel; [id] is this delivery's UUID.
abstract interface class NotificationChannel {
  Future<void> send(Object notifiable, Notification notification, String id);
}

/// A channel whose work can be prepared when the notification is sent and
/// done later by a worker, for [ShouldQueue] notifications: [prepare]
/// returns JSON, [deliver] gets it back in the job.
abstract interface class QueueableNotificationChannel
    implements NotificationChannel {
  Map<String, Object?> prepare(
    Object notifiable,
    Notification notification,
    String id,
  );

  Future<void> deliver(Map<String, Object?> payload);
}

/// A notifiable that decides its own routes (Laravel's
/// `routeNotificationFor<Channel>`): return `null` for the default.
abstract interface class RoutesNotifications {
  Object? routeNotificationFor(String channel, Notification notification);
}

/// Recipients without a model (`Notifications.route('mail', 'a@b.co')`).
final class AnonymousNotifiable implements RoutesNotifications {
  AnonymousNotifiable(this._manager, this.routes);

  final NotificationManager _manager;
  final Map<String, Object> routes;

  /// Adds another channel's route.
  AnonymousNotifiable route(String channel, Object route) {
    routes[channel] = route;
    return this;
  }

  Future<void> notify(Notification notification) =>
      _manager.send(this, notification);

  @override
  Object? routeNotificationFor(String channel, Notification notification) =>
      routes[channel];
}

/// The address of [model]: its `email` attribute, named by `name`.
MailAddress mailAddressOf(Model model) {
  final email = model['email'];
  if (email is! String || email.isEmpty) {
    throw ArgumentError.value(
      model,
      'notifiable',
      '${model.runtimeType} has no email attribute',
    );
  }
  final name = model['name'];
  return MailAddress(email, name is String && name.isNotEmpty ? name : null);
}

/// Sends `toMail` (a [NotificationMail] or a [Mailable]) to the
/// notifiable's address.
final class MailChannel implements NotificationChannel {
  MailChannel(this._mailer, {required this.appName});

  final Mailer _mailer;
  final String appName;

  @override
  Future<void> send(
    Object notifiable,
    Notification notification,
    String id,
  ) async {
    await _mailer.send(mailable(notifiable, notification));
  }

  /// Queues the mail on [queue] after [delay].
  Future<void> queue(
    Object notifiable,
    Notification notification, {
    String? queue,
    String? connection,
    Duration? delay,
  }) => _mailer.queue(
    mailable(notifiable, notification),
    queue: queue,
    connection: connection,
    delay: delay,
  );

  /// The notification's mail, addressed to [notifiable].
  Mailable mailable(Object notifiable, Notification notification) {
    final mail = notification.toMail(notifiable);
    final route = notifiable is RoutesNotifications
        ? notifiable.routeNotificationFor('mail', notification)
        : null;
    final to = route != null
        ? Mailer.addresses(route)
        : notifiable is Model
        ? [mailAddressOf(notifiable)]
        : throw StateError(
            'No mail route for ${notifiable.runtimeType}: use a model with '
            'an email, or Notifications.route(\'mail\', address).',
          );
    final Mailable mailable = switch (mail) {
      final Mailable m => m,
      final NotificationMail m => m.toMailable(
        fallbackSubject: titleFromClass('${notification.runtimeType}'),
        appName: appName,
      ),
      _ => throw StateError(
        '${notification.runtimeType}.toMail must return a NotificationMail '
        'or a Mailable for the mail channel.',
      ),
    };
    mailable.addRecipients(to: to);
    return mailable;
  }
}

/// Stores the notification in Laravel's `notifications` table.
final class DatabaseChannel implements QueueableNotificationChannel {
  DatabaseChannel(this._db);

  final DatabaseManager _db;

  @override
  Future<void> send(Object notifiable, Notification notification, String id) =>
      deliver(prepare(notifiable, notification, id));

  /// The row, built when the notification is sent (its id and timestamps
  /// are those of that moment).
  @override
  Map<String, Object?> prepare(
    Object notifiable,
    Notification notification,
    String id,
  ) {
    if (notifiable is! Model) {
      throw StateError(
        'The database channel needs a model, not ${notifiable.runtimeType}.',
      );
    }
    final now = formatDateTime(Clock.now());
    return {
      'id': id,
      'type': notification.databaseType(notifiable),
      'notifiable_type': notifiable.modelDefinition.morphClass,
      'notifiable_id': notifiable.key,
      'data': jsonEncode(
        notification.toDatabase(notifiable) ?? notification.toArray(notifiable),
      ),
      'read_at': null,
      'created_at': now,
      'updated_at': now,
    };
  }

  @override
  Future<void> deliver(Map<String, Object?> payload) async {
    await _db.table(NotificationManager.table).insert(payload);
  }
}

/// A row of the `notifications` table.
final class DatabaseNotification {
  DatabaseNotification.fromRow(Map<String, Object?> row)
    : id = '${row['id']}',
      type = '${row['type']}',
      data = switch (row['data']) {
        final String text => (jsonDecode(text) as Map).cast<String, Object?>(),
        final Map<Object?, Object?> map => map.cast<String, Object?>(),
        _ => const <String, Object?>{},
      },
      readAt = _date(row['read_at']),
      createdAt = _date(row['created_at']);

  final String id;
  final String type;
  final Map<String, Object?> data;
  final DateTime? readAt;
  final DateTime? createdAt;

  bool get read => readAt != null;

  static DateTime? _date(Object? value) => switch (value) {
    null => null,
    final DateTime d => d,
    final String s => DateTime.tryParse(
      s.contains('T') ? s : '${s.replaceFirst(' ', 'T')}Z',
    ),
    _ => null,
  };
}

/// Sends notifications on their channels (the `Notifications` facade).
final class NotificationManager {
  NotificationManager(
    this._db,
    Mailer mailer, {
    required String appName,
    Map<String, NotificationChannel> channels = const {},
  }) : _channels = {
         'mail': MailChannel(mailer, appName: appName),
         'database': DatabaseChannel(_db),
         ...channels,
       };

  static const String table = 'notifications';

  final DatabaseManager _db;
  final Map<String, NotificationChannel> _channels;
  NotificationFake? _fake;

  /// Adds (or replaces) channel [name].
  void extend(String name, NotificationChannel channel) =>
      _channels[name] = channel;

  /// Sends [notification] to [notifiables] (one or a list), each with its
  /// own id, on the channels its `via` names.
  Future<void> send(Object notifiables, Notification notification) async {
    for (final notifiable in _list(notifiables)) {
      final channels = notification.via(notifiable);
      final fake = _fake;
      if (fake != null) {
        fake.sent.add((
          notifiable: notifiable,
          notification: notification,
          channels: channels,
        ));
        continue;
      }
      final id = KeyGenerator.uuid();
      for (final name in channels) {
        final channel =
            _channels[name] ??
            (throw StateError('No notification channel [$name].'));
        if (notification is ShouldQueue) {
          await _queue(name, channel, notifiable, notification, id);
        } else {
          await channel.send(notifiable, notification, id);
        }
      }
    }
  }

  /// A [ShouldQueue] notification: the mail and queueable channels go to
  /// the queue (prepared now, delivered by a worker); other channels send
  /// right away.
  Future<void> _queue(
    String name,
    NotificationChannel channel,
    Object notifiable,
    Notification notification,
    String id,
  ) async {
    final queued = notification as ShouldQueue;
    switch (channel) {
      case final MailChannel mail:
        await mail.queue(
          notifiable,
          notification,
          queue: queued.queue,
          connection: queued.connection,
          delay: queued.delay,
        );
      case final QueueableNotificationChannel queueable:
        await Container.current.make<QueueManager>().push(
          SendQueuedNotification(
            name,
            queueable.prepare(notifiable, notification, id),
          ),
          queue: queued.queue,
          connection: queued.connection,
          delay: queued.delay,
        );
      default:
        await channel.send(notifiable, notification, id);
    }
  }

  /// Delivers what [SendQueuedNotification] carries.
  Future<void> deliverPrepared(
    String channel,
    Map<String, Object?> payload,
  ) async {
    final target = _channels[channel];
    if (target is! QueueableNotificationChannel) {
      throw StateError('No queueable notification channel [$channel].');
    }
    await target.deliver(payload);
  }

  static List<Object> _list(Object notifiables) =>
      notifiables is Iterable<Object> ? notifiables.toList() : [notifiables];

  /// An on-demand recipient: `route('mail', 'a@b.co').notify(...)`.
  AnonymousNotifiable route(String channel, Object route) =>
      AnonymousNotifiable(this, {channel: route});

  /// The stored notifications of [notifiable], newest first.
  QueryBuilder query(Model notifiable) => _db
      .table(table)
      .where('notifiable_type', notifiable.modelDefinition.morphClass)
      .where('notifiable_id', notifiable.key)
      .orderByDesc('created_at');

  Future<List<DatabaseNotification>> of(
    Model notifiable, {
    bool unreadOnly = false,
  }) async {
    var query = this.query(notifiable);
    if (unreadOnly) {
      query = query.whereNull('read_at');
    }
    return [
      for (final row in await query.get()) DatabaseNotification.fromRow(row),
    ];
  }

  Future<int> unreadCount(Model notifiable) =>
      query(notifiable).whereNull('read_at').count();

  /// Marks [ids] (all of the notifiable's when null) read; returns how
  /// many changed.
  Future<int> markAsRead(Model notifiable, [List<String>? ids]) {
    var query = this.query(notifiable).whereNull('read_at');
    if (ids != null) {
      query = query.whereIn('id', ids);
    }
    final now = formatDateTime(Clock.now());
    return query.update({'read_at': now, 'updated_at': now});
  }

  /// Records notifications instead of sending them (`Notifications.fake()`).
  NotificationFake fake() => _fake = NotificationFake();

  void restore() => _fake = null;
}

/// The job that delivers a queued notification on a queueable channel
/// (`daravel:notification`, registered by the framework).
final class SendQueuedNotification extends Job {
  const SendQueuedNotification(this.channel, this.payload);

  static const String name = 'daravel:notification';

  static final JobDefinition definition = JobDefinition(
    name,
    (json) => SendQueuedNotification(
      json['channel']! as String,
      (json['payload']! as Map).cast<String, Object?>(),
    ),
  );

  final String channel;
  final Map<String, Object?> payload;

  @override
  String get jobName => name;

  @override
  String get displayName => 'Notification ($channel)';

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [Duration(seconds: 10)];

  @override
  Map<String, Object?> toJson() => {'channel': channel, 'payload': payload};

  @override
  Future<void> handle(JobContext ctx) => Container.current
      .make<NotificationManager>()
      .deliverPrepared(channel, payload);
}

/// What `Notifications.fake()` recorded, with Laravel's assertions.
final class NotificationFake {
  final List<
    ({Object notifiable, Notification notification, List<String> channels})
  >
  sent = [];

  static bool _same(Object a, Object b) =>
      identical(a, b) ||
      (a is Model &&
          b is Model &&
          a.runtimeType == b.runtimeType &&
          a.key != null &&
          a.key == b.key) ||
      a == b;

  /// The notifications of type [N] sent to [notifiable] (matching [where]).
  List<N> sentTo<N extends Notification>(
    Object notifiable, [
    bool Function(N notification, List<String> channels)? where,
  ]) => [
    for (final e in sent)
      if (e.notification case final N n
          when _same(e.notifiable, notifiable) &&
              (where == null || where(n, e.channels)))
        n,
  ];

  void assertSentTo<N extends Notification>(
    Object notifiable, [
    bool Function(N notification, List<String> channels)? where,
  ]) {
    if (sentTo<N>(notifiable, where).isEmpty) {
      throw StateError('Expected [$N] to be sent to $notifiable; it was not.');
    }
  }

  void assertNotSentTo<N extends Notification>(Object notifiable) {
    if (sentTo<N>(notifiable).isNotEmpty) {
      throw StateError('Expected [$N] not to be sent to $notifiable; it was.');
    }
  }

  /// Sent to `Notifications.route(...)` recipients.
  void assertSentOnDemand<N extends Notification>([
    bool Function(N notification, AnonymousNotifiable notifiable)? where,
  ]) {
    final found = sent.any(
      (e) =>
          e.notification is N &&
          e.notifiable is AnonymousNotifiable &&
          (where == null ||
              where(e.notification as N, e.notifiable as AnonymousNotifiable)),
    );
    if (!found) {
      throw StateError('Expected [$N] to be sent on demand; it was not.');
    }
  }

  void assertSentTimes<N extends Notification>(int times) {
    final count = sent.where((e) => e.notification is N).length;
    if (count != times) {
      throw StateError('Expected [$N] sent $times time(s); it was $count.');
    }
  }

  void assertNothingSent() {
    if (sent.isNotEmpty) {
      throw StateError(
        'Expected no notifications; got '
        '${sent.map((e) => e.notification.runtimeType).join(', ')}.',
      );
    }
  }
}

/// `user.notify(...)` (Laravel's `Notifiable` trait) for every model.
extension NotifiableModel on Model {
  Future<void> notify(Notification notification) =>
      Container.current.make<NotificationManager>().send(this, notification);

  /// This model's stored notifications, newest first.
  Future<List<DatabaseNotification>> notifications({bool unreadOnly = false}) =>
      Container.current.make<NotificationManager>().of(
        this,
        unreadOnly: unreadOnly,
      );
}

/// Laravel's `notifications` table (`make:notifications-table`). Created
/// only when missing, so a database already migrated by Laravel is fine.
final class CreateNotificationsTable extends Migration {
  const CreateNotificationsTable();

  @override
  String get name => '2026_10_26_000000_create_notifications_table';

  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.createIfNotExists(NotificationManager.table, (table) {
        table.uuid('id').primary();
        table.string('type');
        table.morphs('notifiable');
        table.text('data');
        table.timestamp('read_at').nullable();
        table.timestamps();
      });

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists(NotificationManager.table);
}
