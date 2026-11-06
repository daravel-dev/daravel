import 'package:daravel/daravel.dart';

/// Commands to a running Horizon from another process (`horizon:pause`,
/// `horizon:continue`, `horizon:terminate`), through the cache store the
/// queue's `queue:restart` signal uses (`QueueManager.signalStore`). The
/// master reads the key every second; each command carries the moment it
/// was sent, so it runs once.
abstract final class HorizonSignals {
  /// The key of Horizon [name] (`HORIZON_NAME`, `horizon` by default).
  static String key(String name) => 'horizon:$name:command';

  /// Sends [command] (`pause`, `continue` or `terminate`) to Horizon
  /// [name]; false without a signal store.
  static Future<bool> send(
    CacheRepository? store,
    String name,
    String command,
  ) async {
    if (store == null) {
      return false;
    }
    // A string, which every cache store keeps as it is.
    final at = DateTime.now().microsecondsSinceEpoch;
    await store.store.forever(key(name), '$command|$at');
    return true;
  }

  /// The last command sent to Horizon [name] and when, or null.
  static Future<(String, int)?> read(
    CacheRepository? store,
    String name,
  ) async {
    final value = await store?.store.get(key(name));
    if (value is! String) {
      return null;
    }
    final bar = value.lastIndexOf('|');
    final at = bar < 0 ? null : int.tryParse(value.substring(bar + 1));
    return at == null ? null : (value.substring(0, bar), at);
  }
}
