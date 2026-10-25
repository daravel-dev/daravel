# Feature flags

`Feature` is Laravel Pennant: a feature resolves once per scope (by default
the authenticated user), its value is stored, and later checks read it. The
store is Pennant's `features` table, so a Laravel application on the same
database sees the same flags, which is how a feature can move from one to
the other.

## Defining and checking

Define features at boot, for example in a service provider or
`bootstrap/app.dart`:

```dart
Feature.define('new-scoring-engine', (Object? scope) =>
    scope is User && scope.email.endsWith('@company.com'));

// Rich values: any value but false is active.
Feature.define('checkout', (scope) => scope == null ? 'classic' : 'v2');
```

Check them in controllers, jobs and commands:

```dart
if (await Feature.active('new-scoring-engine')) { ... }
final variant = await Feature.value('checkout');          // 'classic' or 'v2'
await Feature.forScope(team).active('new-scoring-engine'); // another scope
await Feature.allAreActive(['a', 'b']);
```

`forScope` is Pennant's `Feature::for` (`for` is a Dart keyword). A scope is
serialized as Pennant does: `__laravel_null` for none, strings and numbers
as they are, models as `App\Models\User|1` (their `morphClass` and key), or
implement `FeatureScope` for anything else. An undefined feature is
inactive and nothing is stored for it. Within one request, job or command
each value is read once.

## Changing values

```dart
await Feature.activate('checkout', 'v3');      // for the current user
await Feature.forScope(user).deactivate('new-scoring-engine');
await Feature.forget('checkout');               // resolve again next time
await Feature.activateForEveryone('new-scoring-engine');
await Feature.deactivateForEveryone('new-scoring-engine');
await Feature.purge(['checkout']);              // or purge() for all
```

As in Pennant, `activateForEveryone` changes the stored values; scopes that
have none yet still resolve through the definition.

## Routes

`feature:a,b` (Pennant's `EnsureFeaturesAreActive`) answers `400 Bad
Request` unless every listed feature is active for the user; with
`APP_DEBUG` the message names them.

```dart
router.get('/api/v2/scores', scores.index).middleware(const ['feature:new-scoring-engine']);
```

## Storage

`PENNANT_STORE` (Laravel's variable) picks `database` (the default; add
`CreateFeaturesTable()` to `bootstrap/migrations.dart`, which new projects
include) or `array` (memory, per isolate; the default when
`APP_ENV=testing`).
