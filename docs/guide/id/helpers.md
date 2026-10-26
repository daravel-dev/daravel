<!-- source: helpers.md sha256:72ad1806d86f -->
# String, helper, dan koleksi

Utilitas sehari-hari Laravel, dengan nama dan semantik yang sama sejauh
Dart memungkinkan:

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

| Kelompok | Method |
| :-- | :-- |
| Case | `snake`, `kebab`, `camel`, `studly`, `title`, `headline`, `ucfirst`, `lcfirst`, `ucwords` |
| URL | `slug` (huruf Latin beraksen menjadi ASCII, `@` menjadi `at`), `ascii` |
| Memotong | `after`, `afterLast`, `before`, `beforeLast`, `between`, `limit`, `words`, `mask`, `squish`, `start`, `finish`, `replaceFirst`, `replaceLast`, `padBoth`, `padLeft`, `padRight`, `trimChars` |
| Predikat | `contains`, `containsAll`, `startsWith`, `endsWith` (sebuah string atau list needle), `isUuid`, `isUlid`, `isJson`, `isAscii`, `wordCount` |
| Generator | `random` (aman secara kriptografis), `uuid` (v4), `ulid` |
| Infleksi | `plural(word, [count])`, `singular`, `pluralStudly`: aturan bahasa Inggris, bentuk tak beraturan dan kata tak terhitung yang umum; huruf besar-kecil input dipertahankan |

Helper yang sama bisa dirangkai langsung pada string, seperti `Str::of()`
dari Laravel:

```dart
final slug = rawTitle.after(':').squish().slug();
final model = 'blog_posts'.singular().studly();     // BlogPost
final masked = email.mask('*', 3);
if (request.header('x-tenant').isBlank) { ... }    // juga untuk null
```

Method yang sudah dimiliki `String` (`contains`, `startsWith`, `padLeft`, …)
tetap bermakna seperti di Dart; `Str.contains` dan kawan-kawan memberi makna
Laravel. `isBlank`, `isFilled`, `orEmpty`, dan `nullIfBlank` bekerja pada
`String?`.

## Waktu

```dart
await Cache.remember('leaderboard', 10.minutes, Leaderboard.compute);
final expires = 7.days.fromNow;                     // Clock.now() + 7 hari
post.createdAt.diffForHumans();                     // 5 minutes ago
post.createdAt.diffForHumans(locale: 'id');         // 5 menit yang lalu
```

- `5.seconds`, `10.minutes`, `2.hours`, `7.days`, `2.weeks` adalah durasi;
  `.fromNow` dan `.ago` mengubahnya menjadi tanggal.
- Pada `DateTime`: `isPast`, `isFuture`, `isToday`, `startOfDay`,
  `endOfDay`, dan `diffForHumans({other, locale})`.
- Perhitungan kalender seperti Carbon: `addMonths`/`subMonths` dan
  `addYears`/`subYears` meluap (31 Jan ditambah satu bulan menjadi 3 Mar),
  bentuk `…NoOverflow` tetap di bulan tujuan (28 Feb); `startOfWeek` (Senin)
  / `endOfWeek`, `startOfMonth` / `endOfMonth`, `startOfYear` / `endOfYear`
  (berakhir di `.999999`), `daysInMonth`, `isWeekend`, `isWeekday`,
  `isSameDay`, `isSameMonth`, `isSameYear`, dan
  `isBetween(start, end, inclusive:)`.
- Semuanya membaca `Clock`, jadi `freezeTime()` dan `travel()` berlaku.
- `diffForHumans` sama dengan dari Carbon: satuan kalender utuh terbesar
  (`4 weeks ago`, lalu `1 month ago` dari tanggal yang sama di bulan
  sebelumnya), `from now` untuk masa depan, `before`/`after` dengan
  `other:`, dalam bahasa Inggris atau Indonesia (`yang lalu`,
  `dari sekarang`).

## `Number`

`Number` dari Laravel, dengan output yang sama seperti format intl Laravel
untuk locale `en` dan `id` (`Number.useLocale('id')` menetapkan default):

| Pemanggilan | Hasil |
| :-- | :-- |
| `Number.format(1234567.891, precision: 2)` | `1,234,567.89` (`1.234.567,89` di `id`) |
| `Number.percentage(66.666, precision: 1)` | `66.7%` |
| `Number.currency(150000, code: 'IDR', locale: 'id')` | `Rp 150.000,00` |
| `Number.currency(150000, code: 'IDR')` | `IDR 150,000.00` |
| `Number.fileSize(5 * 1024 * 1024)` | `5 MB` |
| `Number.abbreviate(1230000, precision: 2)` | `1.23M` |
| `Number.forHumans(1500)` | `2 thousand` |
| `Number.ordinal(22)` | `22nd` (`ke-22` di `id`) |

Pembulatannya half to even, seperti ICU (`Number.format(2.5, precision: 0)`
menghasilkan `2`). Shortcut: `5242880.toFileSize()`, `1500.abbreviate()`,
`150000.toCurrency(code: 'IDR')`, `22.ordinal()`.

## Helper global

| Helper | Catatan |
| :-- | :-- |
| `abort`, `abortIf`, `abortUnless` | melempar `HttpException`; tanpa pesan, pesan JSON-nya kosong, seperti di Laravel |
| `retry(times, (attempt) async {...}, delay:, backoff:, when:)` | mencoba ulang sampai berhasil, melempar ulang error terakhir |
| `rescue(() async {...}, fallback:, report:)` | mengembalikan `fallback` saat error dan mencatatnya ke log kecuali `report: false` |
| `once(key, () => ...)` | di-memoize per scope request, job, atau command; Dart butuh key eksplisit |
| `blank`, `filled` | `null`, string yang hanya berisi spasi, dan koleksi kosong dianggap blank; `0` dan `false` tidak |
| `tap`, `value`, `dataGet(target, 'a.b.0', fallback)` | `dataGet` membaca map, list, dan model |
| `now()`, `today()` | membaca `Clock`, jadi `freezeTime()` dan `travel()` berlaku |
| `env(key, [fallback])` | environment yang sudah dimuat |

`app()` dari Laravel adalah `App.make<T>()`: `app` global akan tertutup oleh
variabel `app` yang dipakai di mana-mana dalam kode dan test Daravel.
`route()` dan `url()` adalah `router.url(name, params)`. `dd()` dan `dump()`
tidak disediakan.

## Koleksi

Helper koleksi adalah extension pada `Iterable` apa pun (list, set, hasil
query, koleksi model), jadi tidak ada yang perlu dikonversi: `pluck` (path
bertitik), `keyBy`, `groupBy`, `chunk`, `unique([by])`, `sumBy`, `avgBy`,
`sortBy`, `sortByDesc` (stabil), dan `partition`. Semuanya melengkapi
`package:collection` (`firstWhereOrNull`, `slices`, ...), bukan
menggantikannya.
