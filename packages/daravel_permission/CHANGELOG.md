# Changelog

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Version aligned with Daravel 1.19.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Version aligned with Daravel 1.18.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Added: a revocation is relayed through the coordinator (`PermissionRegistrar.listen`, channel `daravel_permission:invalidate`), so the other worker isolates drop their caches as soon as the message lands instead of at their next read of the shared version (up to a second).

- Fixed: the per-isolate access cache is bounded (`PermissionRegistrar.maxCachedModels`, 10 000; `cachedModels`) and kept in order of last use, so a sweep drops cold models, not the ones checked on every request: one entry per model ever checked stayed until the isolate exited.
- Fixed: `hasRole`, `hasAllRoles` and `hasExactRoles` given a `Role` of another guard no longer match a role of the same name under the model's guard (Spatie compares `Role` objects by key).

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: `withPermissions()`, `HasRoles`, `Role` and `Permission` on spatie/laravel-permission's tables (`CreatePermissionTables`), the `role`, `permission` and `role_or_permission` middleware, a gate hook, guards, wildcards, a super-admin role, the `permission:*` commands (`package:daravel_permission/commands.dart`, apart so the server does not compile the CLI) and a cross-isolate cache.
