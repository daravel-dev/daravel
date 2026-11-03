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
import '../broadcasting/broadcast_manager.dart';
import 'notification.dart';

/// Delivers a notification on one channel; [id] is this delivery's UUID.
abstract interface class NotificationChannel {
  /// Sends [notification] to [notifiable] now.
  Future<void> send(Object notifiable, Notification notification, String id);
}

/// A channel whose work can be prepared when the notification is sent and
/// done later by a worker, for [ShouldQueue] notifications: [prepare]
/// returns JSON, [deliver] gets it back in the job.
abstract interface class QueueableNotificationChannel
    implements NotificationChannel {
  /// The payload queued for [notification], when the channel is queued.
  Map<String, Object?> prepare(
    Object notifiable,
    Notification notification,
    String id,
  );

  /// Delivers a queued payload.
  Future<void> deliver(Map<String, Object?> payload);
}

/// A notifiable that decides its own routes (Laravel's
/// `routeNotificationFor<Channel>`): return `null` for the default.
abstract interface class RoutesNotifications {
  /// Where the channel delivers: an email address, a phone number, a
  /// Webhook URL...
  Object? routeNotificationFor(String channel, Notification notification);
}

/// Recipients without a model (`Notifications.route('mail', 'a@b.co')`).
final class AnonymousNotifiable implements RoutesNotifications {
  /// A notifiable that is no model: `Notification.route('mail', email)`.
  AnonymousNotifiable(this._manager, this.routes);

  final NotificationManager _manager;

  /// The address per channel.
  final Map<String, Object> routes;

  /// Adds another channel's route.
  AnonymousNotifiable route(String channel, Object route) {
    routes[channel] = route;
    return this;
  }

  /// Sends [notification] to the routes.
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
  /// Sends notifications as mail, signed with [appName].
  MailChannel(this._mailer, {required this.appName});

  final Mailer _mailer;

  /// The application name in greetings and signatures.
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
  /// Stores notifications in the `notifications` table.
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
  /// A notification read from a row of `notifications`.
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

  /// The notification's UUID.
  final String id;

  /// The notification type.
  final String type;

  /// The notification's data.
  final Map<String, Object?> data;

  /// When it was read, or null.
  final DateTime? readAt;

  /// When it was created.
  final DateTime? createdAt;

  /// Whether it was read.
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

/// Publishes notifications to their channels on the [Broadcaster], as
/// Laravel's `BroadcastNotificationCreated` event: `{"event": ..., "data":
/// {...toBroadcast, "id": ..., "type": ...}}`.
final class BroadcastChannel implements QueueableNotificationChannel {
  /// Broadcasts notifications on the notifiable's private channel.
  BroadcastChannel(this._manager);

  final BroadcastManager _manager;

  @override
  Future<void> send(Object notifiable, Notification notification, String id) =>
      deliver(prepare(notifiable, notification, id));

  @override
  Map<String, Object?> prepare(
    Object notifiable,
    Notification notification,
    String id,
  ) {
    final channels = notification.broadcastOn(notifiable).isNotEmpty
        ? notification.broadcastOn(notifiable)
        : _channelsOf(notifiable, notification);
    return {
      'channels': channels,
      'event': notification.broadcastAs(),
      'data': {
        ...(notification.toBroadcast(notifiable) ??
            notification.toArray(notifiable)),
        'id': id,
        'type': notification.broadcastType(notifiable),
      },
    };
  }

  @override
  Future<void> deliver(Map<String, Object?> payload) => _manager.send(
    payload['event']! as String,
    [for (final channel in payload['channels']! as List<Object?>) '$channel'],
    payload['data'],
  );

  static List<String> _channelsOf(
    Object notifiable,
    Notification notification,
  ) {
    if (notifiable is RoutesNotifications) {
      switch (notifiable.routeNotificationFor('broadcast', notification)) {
        case final String channel:
          return [channel];
        case final List<Object?> channels:
          return [for (final channel in channels) '$channel'];
      }
    }
    // Laravel's PrivateChannel of the model: private-App.Models.User.1.
    if (notifiable is Model) {
      final type = notifiable.modelDefinition.morphClass.replaceAll(r'\', '.');
      return ['private-$type.${notifiable.key}'];
    }
    throw StateError(
      'The broadcast channel needs a model or a route '
      '(Notifications.route(\'broadcast\', \'channel\')).',
    );
  }
}

/// Sends notifications on their channels (the `Notifications` facade).
final class NotificationManager {
  /// A manager sending through the registered channels.
  NotificationManager(
    this._db,
    Mailer mailer, {
    required String appName,
    BroadcastManager? broadcaster,
    Map<String, NotificationChannel> channels = const {},
  }) : _channels = {
         'mail': MailChannel(mailer, appName: appName),
         'database': DatabaseChannel(_db),
         'broadcast': ?broadcaster == null
             ? null
             : BroadcastChannel(broadcaster),
         ...channels,
       };

  /// The notifications table, shared with Laravel.
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

  /// The database notifications of a notifiable, newest first.
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

  /// The number of unread database notifications of [notifiable].
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

  /// Undoes `fake()`.
  void restore() => _fake = null;
}

/// The job that delivers a queued notification on a queueable channel
/// (`daravel:notification`, registered by the framework).
final class SendQueuedNotification extends Job {
  /// A job delivering [payload] through [channel].
  const SendQueuedNotification(this.channel, this.payload);

  /// The job name in the payload.
  static const String name = 'daravel:notification';

  /// The definition to list in `bootstrap/jobs.dart`.
  static final JobDefinition definition = JobDefinition(
    name,
    (json) => SendQueuedNotification(
      json['channel']! as String,
      (json['payload']! as Map).cast<String, Object?>(),
    ),
  );

  /// The channel delivering.
  final String channel;

  /// What it delivers.
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
  /// The notifications sent while faked.
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

  /// Fails unless a notification of type [N] was sent to the notifiable.
  void assertSentTo<N extends Notification>(
    Object notifiable, [
    bool Function(N notification, List<String> channels)? where,
  ]) {
    if (sentTo<N>(notifiable, where).isEmpty) {
      throw StateError('Expected [$N] to be sent to $notifiable; it was not.');
    }
  }

  /// Fails if a notification of type [N] was sent to [notifiable].
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

  /// Fails unless notifications of type [N] were sent [times] times.
  void assertSentTimes<N extends Notification>(int times) {
    final count = sent.where((e) => e.notification is N).length;
    if (count != times) {
      throw StateError('Expected [$N] sent $times time(s); it was $count.');
    }
  }

  /// Fails if any notification was sent.
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
  /// Sends [notification] to this model.
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
  /// The migration creating `notifications`, as Laravel's.
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
