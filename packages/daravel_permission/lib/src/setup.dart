import 'package:daravel/daravel.dart';

import 'config.dart';
import 'has_roles.dart';
import 'middleware.dart';
import 'registrar.dart';

/// `withPermissions()` on the application builder.
extension PermissionApplicationBuilder on ApplicationBuilder {
  /// Adds database roles and permissions (spatie/laravel-permission):
  ///
  /// - the `role`, `permission` and `role_or_permission` middleware;
  /// - a gate hook, so `Gate.allows('posts.edit')`, `can:posts.edit` and
  ///   policies' callers see the user's permissions ([HasRoles]);
  /// - the [PermissionRegistrar] cache (`PERMISSION_*` settings).
  ApplicationBuilder withPermissions() =>
      withConfig<PermissionConfig>(PermissionConfig.fromEnv)
          .withBindings(
            (container) => container.singleton<PermissionRegistrar>((c) {
              final config = c.make<ConfigRepository>();
              return PermissionRegistrar(
                config.section<PermissionConfig>(),
                // One version for every server (a cluster default store) or
                // every process of the machine (the file store).
                () {
                  final cache = c.make<CacheManager>();
                  final store = cache.store();
                  return store.scope == StateScope.cluster
                      ? store
                      : cache.store('file');
                },
              );
            }),
          )
          .withMiddleware(
            (middleware) => middleware
              ..aliasFactory('role', RoleMiddleware.new)
              ..aliasFactory('permission', PermissionMiddleware.new)
              ..aliasFactory(
                'role_or_permission',
                RoleOrPermissionMiddleware.new,
              ),
          )
          .withPolicies((gate) => gate.before(permissionGateHook))
          .withProviders([const _InvalidationRelay()])
          .withShutdown(
            (container) async =>
                container.resolved<PermissionRegistrar>()?.close(),
          );
}

/// Subscribes the registrar to the coordinator's invalidation channel, so
/// a role or permission revoked on one worker isolate is forgotten on the
/// others at once, not at their next read of the shared version.
final class _InvalidationRelay extends ServiceProvider {
  const _InvalidationRelay();

  @override
  Future<void> boot(Container container) => container
      .make<PermissionRegistrar>()
      .listen(container.make<Broadcaster>());
}

/// Spatie's `Gate::before`: a permission the user has answers `true`; any
/// other ability goes on to the gate's definitions and policies (`null`).
/// `PERMISSION_SUPER_ADMIN_ROLE` passes everything.
Future<Object?> permissionGateHook(
  Authenticatable? user,
  String ability,
  List<Object?> args,
) async {
  if (user case final HasRoles model) {
    final superAdmin = PermissionRegistrar.current.config.superAdminRole;
    if (superAdmin != null && await model.hasRole(superAdmin)) {
      return true;
    }
    return await model.checkPermissionTo(ability) ? true : null;
  }
  return null;
}
