import 'dart:async';

import '../auth/contracts.dart';
import '../json_schema/json_schema.dart';

/// Decides whether [user] may join a channel matched by a pattern;
/// [parameters] are its `{placeholders}`. Return `false` (or `null`) to
/// refuse, `true` to admit to a private channel, or the user's public
/// details (a map) to admit to a presence channel.
typedef ChannelAuthorizer = FutureOr<Object?> Function(
  Authenticatable user,
  Map<String, String> parameters,
);

/// Laravel's `routes/channels.php`: who may listen to private and presence
/// channels.
///
/// ```dart
/// .withBroadcasting(channels: (channels) {
///   channels.channel('App.Models.User.{id}',
///       (user, p) => '${user.authIdentifier}' == p['id']);
///   channels.channel('orders.{orderId}', (user, p) async =>
///       (await Order.find(int.parse(p['orderId']!)))?['user_id'] == user.authIdentifier);
///   channels.channel('chat.{room}', (user, p) =>
///       {'id': user.authIdentifier, 'name': (user as User).name});
/// })
/// ```
///
/// Patterns are written without the `private-` or `presence-` prefix, and
/// a placeholder matches up to the next dot, as in Laravel.
final class ChannelRegistry {
  final List<(RegExp, List<String>, ChannelAuthorizer)> _channels = [];
  final List<ChannelDescription> _descriptions = [];

  /// Registers [authorize] for channels matching [pattern].
  ///
  /// [type] (`private`, `presence` or `encrypted`) and [events] describe
  /// the channel for tools, documentation and typed clients
  /// ([describe], `dartisan route:list --channels`); they change nothing
  /// at run time: without [type], the answer of [authorize] decides, as
  /// before (a map for presence).
  void channel(
    String pattern,
    ChannelAuthorizer authorize, {
    String? type,
    List<BroadcastEventSchema> events = const [],
  }) {
    if (type != null && !channelTypes.contains(type)) {
      throw ArgumentError.value(type, 'type', 'one of $channelTypes');
    }
    final names = <String>[];
    final source = pattern.splitMapJoin(
      RegExp(r'\{(.*?)\}'),
      onMatch: (m) {
        names.add(m[1]!);
        return '([^.]+)';
      },
      onNonMatch: RegExp.escape,
    );
    _channels.add((RegExp('^$source\$'), names, authorize));
    _descriptions.add(
      ChannelDescription(
        pattern: pattern,
        type: type,
        parameters: List.unmodifiable(names),
        events: List.unmodifiable(events),
      ),
    );
  }

  /// The channel types [channel] accepts.
  static const List<String> channelTypes = ['private', 'presence', 'encrypted'];

  /// The registered channels, in registration order.
  List<ChannelDescription> describe() => List.unmodifiable(_descriptions);

  /// Removes `private-encrypted-`, `private-` or `presence-` from [channel].
  static String normalize(String channel) {
    for (final prefix in ['private-encrypted-', 'private-', 'presence-']) {
      if (channel.startsWith(prefix)) {
        return channel.substring(prefix.length);
      }
    }
    return channel;
  }

  /// The first registered pattern's answer for [user] on [channel] (with
  /// its prefix), or null when no pattern matches or it refuses.
  Future<Object?> authorize(Authenticatable user, String channel) async {
    final name = normalize(channel);
    for (final (pattern, names, authorizer) in _channels) {
      final match = pattern.firstMatch(name);
      if (match == null) {
        continue;
      }
      final result = await authorizer(user, {
        for (var i = 0; i < names.length; i++) names[i]: match[i + 1]!,
      });
      // As Laravel: false refuses, a truthy answer admits, and a falsy
      // one lets the next pattern decide.
      if (result == false) {
        return null;
      }
      if (result != null) {
        return result;
      }
    }
    return null;
  }
}

/// An event a channel carries, for [ChannelRegistry.describe]: its name and,
/// optionally, the shape of its data. An event class may declare one as
/// `static final schema = BroadcastEventSchema('OrderShipped', data: ...)`;
/// nothing requires it.
final class BroadcastEventSchema {
  /// The event [name] (`broadcastAs`), with [data] as a JSON Schema.
  const BroadcastEventSchema(this.name, {this.data, this.description});

  /// The event's name as clients receive it.
  final String name;

  /// The shape of its payload.
  final SchemaType? data;

  /// What it means.
  final String? description;

  /// `{name, description?, data?}` with [data] as a JSON Schema map.
  Map<String, Object?> toJson() => {
    'name': name,
    'description': ?description,
    if (data case final schema?) 'data': schema.toJson(),
  };
}

/// One registered channel pattern ([ChannelRegistry.describe]).
final class ChannelDescription {
  /// The [pattern] with its [type], [parameters] and [events].
  const ChannelDescription({
    required this.pattern,
    required this.type,
    required this.parameters,
    required this.events,
  });

  /// The pattern, without its prefix (`orders.{orderId}`).
  final String pattern;

  /// `private`, `presence` or `encrypted`; null when the authorizer's
  /// answer decides between private and presence.
  final String? type;

  /// The pattern's `{placeholders}`, in order.
  final List<String> parameters;

  /// The events declared for it.
  final List<BroadcastEventSchema> events;

  /// The channel name a client subscribes to, with its prefix
  /// (`private-orders.{orderId}`); `private-` or `presence-` when the type
  /// is not declared.
  String get channel => switch (type) {
    'presence' => 'presence-$pattern',
    'encrypted' => 'private-encrypted-$pattern',
    'private' => 'private-$pattern',
    _ => '{private,presence}-$pattern',
  };

  /// `{pattern, channel, type, parameters, events}`.
  Map<String, Object?> toJson() => {
    'pattern': pattern,
    'channel': channel,
    'type': type,
    'parameters': parameters,
    'events': [for (final event in events) event.toJson()],
  };
}
