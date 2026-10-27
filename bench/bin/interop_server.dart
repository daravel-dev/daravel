// The Daravel server of bench/interop/run.sh: Laravel Echo, Laravel and
// Laravel Reverb talk to it.
import 'dart:io';

import 'package:daravel/daravel.dart';

final class Member implements Authenticatable {
  const Member(this.id, this.name);
  final int id;
  final String name;
  @override
  Object get authIdentifier => id;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

final class OrderShipped with ShouldBroadcast {
  OrderShipped(this.id);
  final int id;
  @override
  List<String> broadcastOn() => ['private-orders.$id'];
  @override
  Map<String, Object?> broadcastWith() => {'id': id, 'status': 'shipped'};
}

final class Published with ShouldBroadcast {
  @override
  List<String> broadcastOn() => ['news'];
  @override
  String broadcastAs() => 'published';
  @override
  Map<String, Object?> broadcastWith() => {'title': 'Hello from Daravel'};
}

final class Welcome extends Notification {
  const Welcome();
  @override
  List<String> via(Object notifiable) => ['broadcast'];
  @override
  Map<String, Object?> toArray(Object notifiable) => {'text': 'Welcome!'};
}

/// A notifiable without a database: Laravel's App\Models\User 1.
final class UserOne implements RoutesNotifications {
  @override
  Object? routeNotificationFor(String channel, Notification n) =>
      'private-App.Models.User.1';
}

Application createApp() =>
    Application.configure(basePath: Directory.current.path)
        .withAuth((auth) {
          auth.register(
            'token',
            ClosureGuard<Member>(
              name: 'token',
              resolver: (request) => switch (request.bearerToken()) {
                'user-1' => const Member(1, 'Teo'),
                'user-2' => const Member(2, 'Ana'),
                _ => null,
              },
            ),
          );
        })
        .withBroadcasting(
          channels: (channels) {
            channels
              ..channel(
                'App.Models.User.{id}',
                (user, p) => '${user.authIdentifier}' == p['id'],
              )
              ..channel('orders.{id}', (user, p) => true)
              ..channel(
                'chat.{room}',
                (user, p) => {'name': (user as Member).name},
              );
          },
        )
        .withRouting(
          health: '/up',
          api: (r) {
            r.post('/publish', (_) async {
              await Event.dispatch(Published());
              return Response.noContent();
            });
            r
                .post('/ship/{id}', (request) async {
                  await Broadcast.event(
                    OrderShipped(request.param<int>('id')).toOthers(),
                  );
                  return Response.noContent();
                })
                .middleware(const ['auth']);
            r.post('/notify', (_) async {
              await Notifications.send(UserOne(), const Welcome());
              return Response.noContent();
            });
            r.post('/price', (_) async {
              await Broadcast.send(
                'price.updated',
                ['cache-prices'],
                {'sku': 'A1', 'price': 13},
              );
              return Response.noContent();
            });
            r.post('/secret', (_) async {
              await Broadcast.send(
                'secret',
                ['private-encrypted-orders.7'],
                {'code': '4821'},
              );
              return Response.noContent();
            });
          },
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
