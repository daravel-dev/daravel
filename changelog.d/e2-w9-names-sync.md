### Added

- `dartisan names:sync [--check]` (wave 9, W9.6): writes `lib/app/names.dart` from the application's registrations, a `Routes.*` URL builder per named route (path parameters as required or optional named arguments, through `routeUrl`) and `RouteNames`, `Abilities`, `RateLimiters`, `Guards`, `Disks` and `Connections`; `--check` exits 1 when the file is out of date.
- `Application.bootForInspection()`: a boot for tooling that only reads registrations; the metrics publisher does not start and every attempt to open a database connection throws a `StateError` with the reason (`DatabaseManager.refuseConnections`). `names:sync` and `route:list` use it (`DaravelCommand.withAppForInspection`), so they connect to nothing, and a provider that needs the database at boot is reported instead of being run.
- `routeUrl(name, params:, query:, absolute:)`: the named route's URL from the running application's router, with a clear error outside a booted application. `Ability`, an ability name that is its string (`implements String`). `AuthorizationGate.abilities`, `AuthorizationGate.hasPolicies` and `RateLimiter.names`, read-only.

### Changed

- `route:list` boots the application for inspection: it no longer runs a provider that would connect to the database at boot.

### Upgrade notes

- `package:daravel` exports `Ability` and `routeUrl` (from `src/auth/authorization.dart` and `src/routing/router.dart`), and `Application`, `DatabaseManager`, `AuthorizationGate` and `RateLimiter` have the new members above.
- An application whose provider uses the database while booting now gets an error from `route:list` naming that, instead of a connection.
