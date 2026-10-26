import 'dart:async';

import '../auth/contracts.dart';

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

  /// Registers [authorize] for channels matching [pattern].
  void channel(String pattern, ChannelAuthorizer authorize) {
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
  }

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
