import 'package:daravel/daravel.dart';
import 'package:reverb_demo/demo.dart';

/// Who may join which channel (Laravel's `routes/channels.php`).
void registerChannels(ChannelRegistry channels) {
  channels
    // A presence channel: the map is the member the others see.
    ..channel(
      'chat.{room}',
      (user, params) => {
        'id': user.authIdentifier,
        'name': (user as DemoUser).name,
      },
      type: 'presence',
      events: [BroadcastEventSchema('client-typing')],
    )
    // Private and end-to-end encrypted (`private-encrypted-orders.{id}`).
    ..channel(
      'orders.{id}',
      (user, params) => true,
      events: [BroadcastEventSchema('OrderShipped')],
    );
}
