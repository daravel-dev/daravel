# Strings, helpers and collections

Laravel's everyday utilities, with the same names and semantics where Dart
allows:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#support -->
```dart
Str.slug('Laravel & Dart: Hello!'); // laravel-dart-hello
Str.snake('emailVerifiedAt'); // email_verified_at
Str.plural('category'); // categories
Str.limit('The quick brown fox', 9); // The quick...
Str.mask('ana@example.com', '*', 3); // ana************

final rows = [
  {'id': 1, 'role': 'admin', 'total': 10},
  {'id': 2, 'role': 'editor', 'total': 5},
  {'id': 3, 'role': 'admin', 'total': 7},
];
rows.pluck('id'); // [1, 2, 3]
rows.groupBy((row) => row['role']); // {admin: [...], editor: [...]}
rows.sumBy((row) => row['total']! as int); // 22
rows.sortByDesc((row) => row['total']! as int).pluck('id'); // [1, 3, 2]

final rate = await retry(3, (attempt) async => fetchRate(attempt));
final cached = await rescue(() async => fetchRate(0), fallback: 1.0);
blank('  '); // true
dataGet({
  'user': {'name': 'Ana'},
}, 'user.name'); // Ana
```
<!-- /include -->

## `Str`

| Group | Methods |
| :-- | :-- |
| Case | `snake`, `kebab`, `camel`, `studly`, `title`, `headline`, `ucfirst`, `lcfirst`, `ucwords` |
| URLs | `slug` (accented Latin letters become ASCII, `@` becomes `at`), `ascii` |
| Slicing | `after`, `afterLast`, `before`, `beforeLast`, `between`, `limit`, `words`, `mask`, `squish`, `start`, `finish`, `replaceFirst`, `replaceLast`, `padBoth`, `padLeft`, `padRight`, `trimChars` |
| Predicates | `contains`, `containsAll`, `startsWith`, `endsWith` (a string or a list of needles), `isUuid`, `isUlid`, `isJson`, `isAscii`, `wordCount` |
| Generators | `random` (cryptographically secure), `uuid` (v4), `ulid` |
| Inflection | `plural(word, [count])`, `singular`, `pluralStudly`: English rules, common irregulars and uncountables; the case of the input is kept |

## Global helpers

| Helper | Notes |
| :-- | :-- |
| `abort`, `abortIf`, `abortUnless` | throw an `HttpException`; without a message the JSON message is empty, as in Laravel |
| `retry(times, (attempt) async {...}, delay:, backoff:, when:)` | retries until success, rethrows the last error |
| `rescue(() async {...}, fallback:, report:)` | returns `fallback` on error and logs it unless `report: false` |
| `once(key, () => ...)` | memoized per request, job or command scope; Dart needs the explicit key |
| `blank`, `filled` | `null`, whitespace-only strings and empty collections are blank; `0` and `false` are not |
| `tap`, `value`, `dataGet(target, 'a.b.0', fallback)` | `dataGet` reads maps, lists and models |
| `now()`, `today()` | read `Clock`, so `freezeTime()` and `travel()` apply |
| `env(key, [fallback])` | the loaded environment |

Laravel's `app()` is `App.make<T>()`: a global `app` would be shadowed by the
`app` variable that Daravel code and tests use everywhere. `route()` and
`url()` are `router.url(name, params)`. `dd()` and `dump()` are not
provided.

## Collections

The collection helpers are extensions on any `Iterable` (lists, sets,
query results, model collections), so nothing needs converting:
`pluck` (dot paths), `keyBy`, `groupBy`, `chunk`, `unique([by])`, `sumBy`,
`avgBy`, `sortBy`, `sortByDesc` (stable) and `partition`. They complement
`package:collection` (`firstWhereOrNull`, `slices`, ...) rather than replace
it.
