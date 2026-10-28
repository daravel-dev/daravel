import 'package:daravel/daravel.dart';

import 'config.dart';
import 'wildcard.dart';

/// A model's roles and permissions of one guard.
typedef Access = ({Set<String> roles, Set<String> permissions});

/// Keeps every model's roles and permissions in this isolate's memory, so a
/// check is a set lookup instead of a join per request.
///
/// A version number in a shared cache store invalidates them: the default
/// store when it spans servers (`database`, `redis`), else the `file` store,
/// which every process of the machine reads (a `dartisan permission:*`
/// command included). Any change made through Daravel bumps it: this
/// isolate reloads at once, the others within [versionCheck]. Entries also
/// expire after [PermissionConfig.cacheTtl], which bounds how long a change
/// made by a Laravel application sharing the tables takes to show.
final class PermissionRegistrar {
  PermissionRegistrar(
    this.config,
    this._shared, {
    this.versionCheck = const Duration(seconds: 1),
  });

  /// How often this isolate reads the shared version: a check stays a
  /// memory lookup.
  final Duration versionCheck;
  int? _knownVersion;
  DateTime _checkedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final PermissionConfig config;
  final CacheRepository Function() _shared;

  /// The registrar of the current application.
  static PermissionRegistrar get current =>
      Container.current.make<PermissionRegistrar>();

  static const String _versionKey = 'daravel_permission:version';

  /// The most models whose roles and permissions this isolate caches
  /// before stale entries are swept.
  static const int maxCachedModels = 10000;

  /// Models cached on this isolate.
  int get cachedModels => _local.length;

  final Map<String, ({int version, DateTime expires, Access access})> _local =
      {};
  final Map<String, ({int version, DateTime expires, Set<String> names})>
  _allPermissions = {};

  Future<int> _version() async {
    // Wall clock: a polling interval, not domain time.
    final now = DateTime.now();
    final known = _knownVersion;
    if (known != null && now.difference(_checkedAt) < versionCheck) {
      return known;
    }
    _checkedAt = now;
    return _knownVersion = await _shared().get<int>(_versionKey) ?? 0;
  }

  /// Forgets every cached role and permission, on every isolate: this one
  /// at once, the others as soon as the coordinator relays the
  /// invalidation ([listen]), and in any case within [versionCheck].
  Future<void> forgetCachedPermissions() async {
    _local.clear();
    _allPermissions.clear();
    _knownVersion = await _shared().increment(_versionKey);
    _checkedAt = DateTime.now();
    final broadcaster = _broadcaster;
    if (broadcaster != null) {
      try {
        await broadcaster.publish(invalidationChannel, '$_knownVersion');
      } on Object {
        // The version in the shared store still reaches every isolate
        // within versionCheck.
      }
    }
  }

  /// The coordinator channel a revocation is announced on, so the other
  /// worker isolates drop their caches at once instead of at their next
  /// read of the shared version.
  static const String invalidationChannel = 'daravel_permission:invalidate';

  Broadcaster? _broadcaster;
  BroadcastSubscription? _subscription;

  /// Announces this isolate's revocations on [broadcaster] and drops this
  /// isolate's caches when another announces one. Called at boot.
  Future<void> listen(Broadcaster broadcaster) async {
    _broadcaster = broadcaster;
    final subscription = await broadcaster.subscribe(invalidationChannel);
    _subscription = subscription;
    subscription.messages.listen((version) {
      _local.clear();
      _allPermissions.clear();
      // Re-read the shared version on the next check, whatever the poll.
      _knownVersion = int.tryParse(version) ?? _knownVersion;
      _checkedAt = DateTime.now();
    });
  }

  /// Stops listening (at shutdown).
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _broadcaster = null;
  }

  /// The roles and permissions (direct and through roles) of the model
  /// [type] / [id] for [guard].
  Future<Access> accessOf(String type, Object id, String guard) async {
    final key = '$type#$id#$guard';
    final version = await _version();
    final now = Clock.now();
    final cached = _local[key];
    if (cached != null &&
        cached.version == version &&
        cached.expires.isAfter(now)) {
      // Most recently used last, so the sweep below drops cold entries.
      _local.remove(key);
      _local[key] = cached;
      return cached.access;
    }
    final access = await _load(type, id, guard);
    if (_local.length >= maxCachedModels) {
      // One entry per model ever checked on this isolate: bounded by
      // dropping what a newer version or the TTL has already retired, and
      // when that is not enough, the oldest half.
      _local.removeWhere(
        (_, entry) => entry.version != version || !entry.expires.isAfter(now),
      );
      if (_local.length >= maxCachedModels) {
        for (final old in _local.keys.take(_local.length ~/ 2).toList()) {
          _local.remove(old);
        }
      }
    }
    _local.remove(key);
    _local[key] = (
      version: version,
      expires: now.add(config.cacheTtl),
      access: access,
    );
    return access;
  }

  /// Every permission name of [guard] (to tell an unknown permission from
  /// one the model lacks).
  Future<Set<String>> permissionNames(String guard) async {
    final version = await _version();
    final now = Clock.now();
    final cached = _allPermissions[guard];
    if (cached != null &&
        cached.version == version &&
        cached.expires.isAfter(now)) {
      return cached.names;
    }
    final names = {
      for (final row
          in await DB.table('permissions').where('guard_name', guard).select([
            'name',
          ]).get())
        '${row['name']}',
    };
    _allPermissions[guard] = (
      version: version,
      expires: now.add(config.cacheTtl),
      names: names,
    );
    return names;
  }

  static Future<Access> _load(String type, Object id, String guard) async {
    final roles = await DB
        .table('model_has_roles')
        .join('roles', 'roles.id', '=', 'model_has_roles.role_id')
        .where('model_has_roles.model_type', type)
        .where('model_has_roles.model_id', id)
        .where('roles.guard_name', guard)
        .select(['roles.id', 'roles.name'])
        .get();
    final direct = await DB
        .table('model_has_permissions')
        .join(
          'permissions',
          'permissions.id',
          '=',
          'model_has_permissions.permission_id',
        )
        .where('model_has_permissions.model_type', type)
        .where('model_has_permissions.model_id', id)
        .where('permissions.guard_name', guard)
        .select(['permissions.name'])
        .get();
    final roleIds = [for (final row in roles) row['id']];
    final viaRoles = roleIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await DB
              .table('role_has_permissions')
              .join(
                'permissions',
                'permissions.id',
                '=',
                'role_has_permissions.permission_id',
              )
              .whereIn('role_has_permissions.role_id', roleIds)
              .where('permissions.guard_name', guard)
              .select(['permissions.name'])
              .get();
    return (
      roles: {for (final row in roles) '${row['name']}'},
      permissions: {
        for (final row in [...direct, ...viaRoles]) '${row['name']}',
      },
    );
  }

  /// Whether [granted] imply [permission] with wildcards ([wildcardImplies]).
  static bool implies(Iterable<String> granted, String permission) =>
      wildcardImplies(granted, permission);
}
