import 'dart:async';

import 'package:meta/meta.dart';

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
  final List<(ChannelPattern, List<String>, ChannelAuthorizer)> _channels = [];

  /// Registers [authorize] for channels matching [pattern].
  void channel(String pattern, ChannelAuthorizer authorize) {
    final compiled = ChannelPattern(pattern);
    _channels.add((compiled, compiled.names, authorize));
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
      final values = pattern.match(name);
      if (values == null) {
        continue;
      }
      final result = await authorizer(user, {
        for (var i = 0; i < names.length; i++) names[i]: values[i],
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

/// A channel pattern such as `orders.{id}`, matched as Laravel's
/// `Broadcaster::channelNameMatchesPattern` matches it
/// (`/^orders\.([^\.]+)$/`: the whole name, each `{placeholder}` one or
/// more characters other than `.`), in time linear in the name.
///
/// The regular expression it replaces backtracked: two or more
/// placeholders not separated by `.` (`chat-{a}-{b}`) or side by side
/// (`{a}{b}{c}`) took time quadratic, cubic and so on in the name's length
/// on a name they did not match. PHP's backtrack limit bounds it for
/// Laravel; Dart's regular expressions have none. Here a table of which
/// positions the rest of the pattern can match from is filled once
/// (placeholders × name length), and each placeholder then takes the
/// longest value the rest still matches after, which is the value the
/// regular expression's greedy groups found.
@visibleForTesting
final class ChannelPattern {
  /// [pattern] split into its literal parts and `{placeholders}`.
  ChannelPattern(String pattern) {
    var at = 0;
    for (final match in RegExp(r'\{(.*?)\}').allMatches(pattern)) {
      if (match.start > at) {
        _tokens.add(pattern.substring(at, match.start));
      }
      _tokens.add(null);
      names.add(match[1]!);
      at = match.end;
    }
    if (at < pattern.length) {
      _tokens.add(pattern.substring(at));
    }
  }

  /// The placeholder names, in order.
  final List<String> names = [];

  /// Literal parts, and `null` for each placeholder.
  final List<String?> _tokens = [];

  /// The placeholders' values when [name] matches the whole pattern, in
  /// the order of [names]; `null` when it does not.
  List<String>? match(String name) {
    final n = name.length;
    final k = _tokens.length;
    // The end of the run of non-dots starting at each position: where a
    // placeholder starting there must stop at the latest.
    final runEnd = List<int>.filled(n + 1, n);
    for (var p = n - 1; p >= 0; p--) {
      runEnd[p] = name.codeUnitAt(p) == 0x2e ? p : runEnd[p + 1];
    }
    // can[i][p]: tokens i.. match name[p..n) exactly.
    final can = List<List<bool>>.generate(
      k + 1,
      (_) => List<bool>.filled(n + 1, false),
    );
    can[k][n] = true;
    for (var i = k - 1; i >= 0; i--) {
      final token = _tokens[i];
      final next = can[i + 1];
      final row = can[i];
      if (token != null) {
        for (var p = 0; p + token.length <= n; p++) {
          row[p] = next[p + token.length] && name.startsWith(token, p);
        }
        continue;
      }
      // A placeholder from p ends at some q in (p, runEnd[p]] with
      // next[q]: counted with suffix sums of next.
      final after = List<int>.filled(n + 2, 0);
      for (var q = n; q >= 0; q--) {
        after[q] = after[q + 1] + (next[q] ? 1 : 0);
      }
      for (var p = 0; p < n; p++) {
        final end = runEnd[p];
        row[p] = end > p && after[p + 1] - after[end + 1] > 0;
      }
    }
    if (!can[0][0]) {
      return null;
    }
    final values = <String>[];
    var p = 0;
    for (var i = 0; i < k; i++) {
      final token = _tokens[i];
      if (token != null) {
        p += token.length;
        continue;
      }
      // The longest value after which the rest still matches.
      var q = runEnd[p];
      while (!can[i + 1][q]) {
        q--;
      }
      values.add(name.substring(p, q));
      p = q;
    }
    return values;
  }
}
