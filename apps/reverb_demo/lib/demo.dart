import 'package:daravel/daravel.dart';

/// A signed-in user of the demo: `Authorization: Bearer user-1` (Ana, who
/// may open the dashboard) or `user-2` (Budi).
final class DemoUser implements Authenticatable {
  /// The user [id] called [name].
  const DemoUser(this.id, this.name);

  /// The user's id.
  final int id;

  /// The name presence channels show.
  final String name;

  /// Whether the user may open `/reverb`.
  bool get isAdmin => id == 1;

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

/// The demo's users, by bearer token.
DemoUser? demoUser(String? token) => switch (token) {
  'user-1' => const DemoUser(1, 'Ana'),
  'user-2' => const DemoUser(2, 'Budi'),
  _ => null,
};

/// An order shipped: on `private-orders.{id}` and, sealed, on
/// `private-encrypted-orders.{id}`.
final class OrderShipped with ShouldBroadcast {
  /// Order [id] shipped.
  OrderShipped(this.id);

  /// The order.
  final int id;

  @override
  List<String> broadcastOn() => [
    'private-orders.$id',
    'private-encrypted-orders.$id',
  ];

  @override
  Map<String, Object?> broadcastWith() => {'id': id, 'status': 'shipped'};
}
