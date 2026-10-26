import '../database/orm/model.dart';
import '../foundation/container.dart';
import '../notifications/notification.dart';
import '../notifications/notification_manager.dart';

/// Laravel's `Notification` facade (plural here: `Notification` is the
/// base class):
///
/// ```dart
/// await Notifications.send(users, InvoicePaid(invoice));
/// await Notifications.route('mail', 'ops@example.com').notify(Alert());
///
/// final notifications = Notifications.fake();
/// // ...
/// notifications.assertSentTo<InvoicePaid>(user);
/// ```
abstract final class Notifications {
  static NotificationManager get manager =>
      Container.current.make<NotificationManager>();

  /// Sends to one notifiable or a list of them.
  static Future<void> send(Object notifiables, Notification notification) =>
      manager.send(notifiables, notification);

  /// A recipient without a model.
  static AnonymousNotifiable route(String channel, Object route) =>
      manager.route(channel, route);

  /// The stored notifications of [notifiable], newest first.
  static Future<List<DatabaseNotification>> of(
    Model notifiable, {
    bool unreadOnly = false,
  }) => manager.of(notifiable, unreadOnly: unreadOnly);

  static Future<int> unreadCount(Model notifiable) =>
      manager.unreadCount(notifiable);

  static Future<int> markAsRead(Model notifiable, [List<String>? ids]) =>
      manager.markAsRead(notifiable, ids);

  static void extend(String name, NotificationChannel channel) =>
      manager.extend(name, channel);

  static NotificationFake fake() => manager.fake();

  static void restore() => manager.restore();
}
