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

The same helpers chain on the string itself, like Laravel's `Str::of()`:

```dart
final slug = rawTitle.after(':').squish().slug();
final model = 'blog_posts'.singular().studly();     // BlogPost
final masked = email.mask('*', 3);
if (request.header('x-tenant').isBlank) { ... }    // also on null
```

Methods that `String` already has (`contains`, `startsWith`, `padLeft`, …)
keep their Dart meaning; `Str.contains` and friends give Laravel's.
`isBlank`, `isFilled`, `orEmpty` and `nullIfBlank` work on `String?`.

## Time

```dart
await Cache.remember('leaderboard', 10.minutes, Leaderboard.compute);
final expires = 7.days.fromNow;                     // Clock.now() + 7 days
post.createdAt.diffForHumans();                     // 5 minutes ago
post.createdAt.diffForHumans(locale: 'id');         // 5 menit yang lalu
```

- `5.seconds`, `10.minutes`, `2.hours`, `7.days`, `2.weeks` are durations;
  `.fromNow` and `.ago` turn them into dates.
- On a `DateTime`: `isPast`, `isFuture`, `isToday`, `startOfDay`,
  `endOfDay` and `diffForHumans({other, locale})`.
- Calendar math as Carbon: `addMonths`/`subMonths` and `addYears`/`subYears`
  overflow (Jan 31 plus one month is Mar 3), the `…NoOverflow` forms stay in
  the target month (Feb 28); `startOfWeek` (Monday) / `endOfWeek`,
  `startOfMonth` / `endOfMonth`, `startOfYear` / `endOfYear` (ends at
  `.999999`), `daysInMonth`, `isWeekend`, `isWeekday`, `isSameDay`,
  `isSameMonth`, `isSameYear` and `isBetween(start, end, inclusive:)`.
- Everything reads `Clock`, so `freezeTime()` and `travel()` apply.
- `diffForHumans` is Carbon's: the largest whole calendar unit (`4 weeks
  ago`, then `1 month ago` from the same day of the previous month),
  `from now` for the future, `before`/`after` with `other:`, in English or
  Indonesian (`yang lalu`, `dari sekarang`).

## `Number`

Laravel's `Number`, with the same output as Laravel's intl formatting for
the `en` and `id` locales (`Number.useLocale('id')` sets the default):

| Call | Result |
| :-- | :-- |
| `Number.format(1234567.891, precision: 2)` | `1,234,567.89` (`1.234.567,89` in `id`) |
| `Number.percentage(66.666, precision: 1)` | `66.7%` |
| `Number.currency(150000, code: 'IDR', locale: 'id')` | `Rp 150.000,00` |
| `Number.currency(150000, code: 'IDR')` | `IDR 150,000.00` |
| `Number.fileSize(5 * 1024 * 1024)` | `5 MB` |
| `Number.abbreviate(1230000, precision: 2)` | `1.23M` |
| `Number.forHumans(1500)` | `2 thousand` |
| `Number.ordinal(22)` | `22nd` (`ke-22` in `id`) |

Rounding is half to even, as ICU rounds (`Number.format(2.5, precision: 0)`
is `2`). Shortcuts: `5242880.toFileSize()`, `1500.abbreviate()`,
`150000.toCurrency(code: 'IDR')`, `22.ordinal()`.

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
