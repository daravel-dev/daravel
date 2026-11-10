import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// An event that declares the shape of its data (optional).
final class OrderShipped {
  static final BroadcastEventSchema schema = BroadcastEventSchema(
    'OrderShipped',
    description: 'An order left the warehouse.',
    data: JsonSchema.object({
      'id': JsonSchema.integer().required(),
      'carrier': JsonSchema.string(),
    }),
  );
}

void main() {
  test('describe(): patterns, types, parameters and event schemas', () {
    final channels = ChannelRegistry()
      ..channel(
        'orders.{orderId}',
        (user, p) => true,
        type: 'private',
        events: [OrderShipped.schema],
      )
      ..channel('chat.{room}', (user, p) => {'id': 1}, type: 'presence')
      ..channel('App.Models.User.{id}', (user, p) => true);
    expect(
      [for (final c in channels.describe()) c.toJson()],
      [
        {
          'pattern': 'orders.{orderId}',
          'channel': 'private-orders.{orderId}',
          'type': 'private',
          'parameters': ['orderId'],
          'events': [
            {
              'name': 'OrderShipped',
              'description': 'An order left the warehouse.',
              'data': OrderShipped.schema.data!.toJson(),
            },
          ],
        },
        {
          'pattern': 'chat.{room}',
          'channel': 'presence-chat.{room}',
          'type': 'presence',
          'parameters': ['room'],
          'events': <Object?>[],
        },
        {
          'pattern': 'App.Models.User.{id}',
          'channel': '{private,presence}-App.Models.User.{id}',
          'type': null,
          'parameters': ['id'],
          'events': <Object?>[],
        },
      ],
    );
    final data = OrderShipped.schema.data!.toJson();
    expect(data['type'], 'object');
    expect(data['required'], ['id']);
  });

  test(
    'an unknown type is refused; describe() changes nothing at run time',
    () {
      expect(
        () => ChannelRegistry().channel('x', (user, p) => true, type: 'public'),
        throwsArgumentError,
      );
    },
  );
}
