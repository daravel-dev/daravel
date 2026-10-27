import 'package:daravel/daravel.dart';

/// `config/permission.php` (spatie/laravel-permission).
final class PermissionConfig implements ConfigSection {
  const PermissionConfig({
    this.guard = 'web',
    this.cacheTtl = const Duration(minutes: 5),
    this.wildcard = false,
    this.superAdminRole,
    this.displayRoleInException = false,
    this.displayPermissionInException = false,
  });

  factory PermissionConfig.fromEnv(Env env) {
    final superAdmin = env.maybeString('PERMISSION_SUPER_ADMIN_ROLE');
    return PermissionConfig(
      guard: env.string('PERMISSION_GUARD', 'web'),
      cacheTtl: env.duration(
        'PERMISSION_CACHE_TTL',
        const Duration(minutes: 5),
      ),
      wildcard: env.boolean('PERMISSION_WILDCARD', false),
      superAdminRole: superAdmin == null || superAdmin.isEmpty
          ? null
          : superAdmin,
      displayRoleInException: env.boolean(
        'PERMISSION_DISPLAY_ROLE_IN_EXCEPTION',
        false,
      ),
      displayPermissionInException: env.boolean(
        'PERMISSION_DISPLAY_PERMISSION_IN_EXCEPTION',
        false,
      ),
    );
  }

  /// The `guard_name` of roles and permissions a model gets when it does not
  /// say ([HasRoles.guardName]): `web`, Laravel's default guard, so rows
  /// written by a Laravel application match (`PERMISSION_GUARD`).
  final String guard;

  /// How long a model's roles and permissions are kept in memory
  /// (`PERMISSION_CACHE_TTL`). Changes made through Daravel apply at once on
  /// every isolate; changes made by a Laravel application sharing the
  /// tables, within this time.
  final Duration cacheTtl;

  /// `posts.*` grants `posts.edit` (`PERMISSION_WILDCARD`, Spatie's
  /// `enable_wildcard_permission`).
  final bool wildcard;

  /// A role that passes every gate check (`PERMISSION_SUPER_ADMIN_ROLE`):
  /// Spatie's documented `Gate::before` pattern, off by default.
  final String? superAdminRole;

  /// Spatie's `display_role_in_exception` and
  /// `display_permission_in_exception`.
  final bool displayRoleInException;
  final bool displayPermissionInException;

  @override
  String get key => 'permission';

  @override
  Map<String, Object?> toMap() => {
    'guard': guard,
    'cache_ttl_seconds': cacheTtl.inSeconds,
    'enable_wildcard_permission': wildcard,
    'super_admin_role': superAdminRole,
    'display_role_in_exception': displayRoleInException,
    'display_permission_in_exception': displayPermissionInException,
  };
}
