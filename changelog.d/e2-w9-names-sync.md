### Added

- `dartisan names:sync [--check] [--boot]` (wave 9, W9.6) writes `lib/app/names.dart` from the application's registrations: a `Routes.*` URL builder per named route, through `routeUrl`, whose dartdoc gives its methods and pattern, and `RouteNames`, `Abilities`, `RateLimiters`, `Guards`, `Disks` and `Connections`. Path parameters are read as the router reads them: `{post}`, `:id`, `{post:slug}` and the wildcards `{path*}`/`*path` are required (the router matches no empty wildcard), `{slug?}` is optional. Names are taken in sorted order, so the file is the same on every machine. `--check` exits 1 when the file is out of date.
- `names:sync` boots the application for inspection, with no database connection; `--boot` boots it fully, for a provider that needs the database while booting, and the error of a failed inspection boot says so.
- `Application.bootForInspection()`: a boot for tooling that only reads registrations. The metrics publisher, the only timer `boot()` starts, does not start, and every attempt to open a database connection throws a `StateError` with the reason (`DatabaseManager.refuseConnections`). `route:list` keeps its ordinary boot.
- `routeUrl(name, params:, query:, absolute:)`: the named route's URL from the running application's router, with a clear error outside a booted application. `Ability`, an ability name that is its string (`implements String`). `AuthorizationGate.abilities`, `AuthorizationGate.hasPolicies` and `RateLimiter.names`, read-only.

### Upgrade notes

- New public names in `package:daravel/daravel.dart`: `Ability`, `routeUrl`, `Application.bootForInspection`, `Application.inspecting`, `DatabaseManager.refuseConnections`, `AuthorizationGate.abilities`, `AuthorizationGate.hasPolicies` and `RateLimiter.names`.
- New public names in `package:dartisan_cli`: `NamesSyncCommand`, `DaravelCommand.withAppForInspection`, `routeParams`, `RouteParam`, `namesRegion` and `syncNamesSource`.
