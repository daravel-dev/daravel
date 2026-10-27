<!-- source: query-filters.md sha256:e678f2094294 -->
# Query filter

`daravel_teorion` mengubah query string sebuah listing menjadi filter, eager
load, count, sort, dan pagination, dalam whitelist yang Anda deklarasikan
sekali per model. Paket ini adalah port dari
[laravel-teorion](https://packagist.org/packages/teoprayoga/laravel-teorion)
dengan format request yang sama, sehingga satu client bisa dipakai untuk API
Laravel maupun Daravel.

```bash
dart pub add daravel_teorion
dartisan make:query-filter Post
```

```dart
// lib/app/query_filters/post_query_filter.dart
final class PostQueryFilter extends QueryFilter<Post> {
  @override
  Map<String, Filter> get filters => {
    'search': Filter.multiLike(['title', 'body']).alias('q'),
    'status': Filter.enum_('status', PostStatus.values),
    'is_active': Filter.boolean().withDefault(true),
    'author_id': Filter.exact(),
    'has_comments': Filter.has('comments'),
  };

  @override
  List<String> get allowedScopes => ['published', 'popular'];

  @override
  List<String> get allowedWiths => ['author', 'tags'];

  @override
  List<String> get allowedWithCounts => ['comments'];

  @override
  List<String> get allowedSorts => ['created_at', 'title', 'views'];

  @override
  List<String> get defaultSort => ['-created_at'];
}
```

`make:query-filter` mendaftarkannya di `bootstrap/query_filters.dart`;
berikan map itu ke aplikasi, dan controller cukup satu baris:

```dart
Application.configure(basePath: basePath).withQueryFilters(queryFilters)

router.get('/posts', (request) => Post.definition.query().filterAndPaginate(request));
router.get('/posts/{id}', (request) =>
    Post.definition.query().findFiltered(request, request.param<String>('id')));
```

Model juga bisa menyebut filternya sendiri (`with Filterable<Post>` dan
`newQueryFilter()`), dan setiap pemanggilan bisa memberikan filter:
`filterAndPaginate(request, AdminPostQueryFilter())`. `filter(request)`
mengembalikan query, untuk dilanjutkan dengan `.where(...)`, `.get()`, atau
`.first()`.

## Request

| Parameter | Contoh | Efek |
| :-- | :-- | :-- |
| Filter yang dideklarasikan | `?q=dart&status=published` | Diterapkan bila ada (atau dengan default-nya) |
| `scopes[]` | `?scopes[]=published` | Scope model, diberi seluruh request |
| `scopes[N]` | `?scopes[0][name]=byAuthor&scopes[0][params][author_id]=3` | Scope, hanya diberi parameternya sendiri |
| `withs[]` | `?withs[]=author&withs[]=tags` | Eager load (setiap path harus terdaftar di `allowedWiths`) |
| `withs[]` dengan kolom | `?withs[]=author:id,name` | Hanya kolom-kolom itu, bila `allowedWithColumns` mendaftarnya |
| `withCounts[]` | `?withCounts[]=comments` | `comments_count` |
| `withAggregates` | `?withAggregates[comments][sum][]=score` | `comments_sum_score` (juga `avg`, `min`, `max`, `count`) |
| `sort` | `?sort=-created_at,title` | `-` untuk menurun |
| `order[N]`, `order_by` | `?order_by=title&order_direction=desc` | Format lama |
| `order_null_bottoms[]` | `?order_null_bottoms[]=published_at` | NULL di akhir |
| `is_paginate`, `per_page` | `?is_paginate=1&per_page=20` | Satu halaman (`LengthAwarePaginator`), bukan semua baris |
| `pagination=cursor`, `cursor` | `?pagination=cursor&per_page=20` | `CursorPaginator` |
| `max_results` | `?max_results=5` | Paling banyak sejumlah itu, tanpa paging |
| `with_trashed`, `only_trashed` | `?with_trashed=1` | Pada model yang memakai soft delete |
| `visibles[]`, `hiddens[]` | `?hiddens[]=email` | Menyembunyikan atribut, atau menampilkan atribut tersembunyi yang Anda daftar di `allowedVisibles` |

Tanpa `is_paginate` atau `pagination`, semua baris yang cocok dikembalikan,
seperti di laravel-teorion (10 per halaman secara default saat paging,
`TEORION_DEFAULT_PER_PAGE`). `per_page` dan `max_results` dibatasi
`TEORION_MAX_PER_PAGE` (100, sama dengan `max:100` pada aturan validasi);
nilai di bawah 1 berarti default.

Kolom sort atau scope di luar whitelist dijawab 400 dengan pesan dari
laravel-teorion (`Sort column [password] is not in the allowed sorts
list.`), begitu pula filter wajib yang tidak ada. Relasi di luar
`allowedWiths`, yang berisi path lengkap (`author` tidak membuka
`author.posts`), atribut tersembunyi di luar `allowedVisibles` (kosong
secara default: laravel-teorion membiarkan client membuka atribut apa pun,
Daravel tidak), dan scope yang diizinkan tetapi tidak didefinisikan model,
dilewati, kecuali `TEORION_STRICT` (default mengikuti `APP_DEBUG`) juga
menolaknya.

Client hanya bisa memilih kolom sebuah relasi dari kolom yang Anda daftar,
per path relasi; relasi tanpa daftar dimuat utuh dan permintaan kolom
untuknya ditolak, begitu pula kolom lain (`Column [password] of relation
[author] is not in the allowed with columns list.` dalam mode strict). Key
yang dipakai relasi untuk mencocokkan ditambahkan, sehingga `author:name`
tetap menemukan author-nya.

```dart
@override
Map<String, List<String>> get allowedWithColumns => {
  'author': ['id', 'name', 'avatar'],
  'author.country': ['name'],
};
```

## Filter

| Filter | SQL |
| :-- | :-- |
| `Filter.exact()` | `col = ?` |
| `Filter.like()`, `Filter.multiLike([...])` | `col LIKE %?%`, `(a LIKE %?% OR b LIKE %?%)` |
| `Filter.boolean()` | `col = 1` atau `0` |
| `Filter.null_()` | `col IS NOT NULL` untuk nilai true, `IS NULL` selain itu |
| `Filter.enum_(col, values)` | `col = ?` untuk salah satu `values`; nilai lain tidak cocok dengan apa pun |
| `Filter.in_()` | `col IN (...)` dari `a,b` atau `col[]=a&col[]=b` |
| `Filter.date()`, `Filter.dateRange(col, 'start_date', 'end_date')` | `DATE(col) = ?`, `col BETWEEN ? AND ?` |
| `Filter.between()`, `Filter.range()` | `BETWEEN` dari `a,b`; `>=`/`<=` dari `<param>_min` / `<param>_max` |
| `Filter.gt(col, orEqual)`, `Filter.lt(...)` | `col > ?`, `col < ?` |
| `Filter.has('comments')` | `EXISTS` / `NOT EXISTS` |
| `Filter.jsonContains()` | `whereJsonContains(col, value)` |
| `Filter.callback((query, value, param, request) {...})` | Milik Anda |
| `Filter.scope('name')`, `Filter.macro('name')` | Scope model; tipe yang didaftarkan dengan `FilterMacroRegistry.register` |

Masing-masing menerima `.alias('q')`, `.withDefault(value)`, dan
`.required()`. Nama dengan garis bawah (`enum_`, `in_`, `null_`) menghindari
keyword Dart.

## Validasi, dokumentasi, dan audit

`PostQueryFilter().validationRules` memberi form request aturan untuk
parameter listing dan setiap filter (`HasQueryFilterRules` dari
laravel-teorion); `openApiParameters` mendeskripsikannya untuk referensi
API.

Dengan `TEORION_AUDIT_ENABLED=true`, setiap listing mengirim `QueryAudited`
berisi fingerprint (SHA-256 dari filter, model, dan parameter request, tanpa
memedulikan urutan dan halamannya), mode terminal, jumlah hasil, durasi,
dan user; `TEORION_AUDIT_LOG` juga mencatatnya ke log, dan
`TEORION_AUDIT_SAMPLE_RATE` mengaudit sebagian fingerprint, selalu yang
sama.

## Perbedaan dengan laravel-teorion

- `order_null_bottoms[]` hanya menerima kolom sort yang diizinkan, dengan
  quoting; laravel-teorion menulis nilainya ke SQL apa adanya.
- `withs[]=relation:columns` hanya menerima kolom yang didaftar
  `allowedWithColumns`; laravel-teorion meneruskan kolom apa pun, termasuk
  yang tersembunyi.
- `Filter.range()` dan `Filter.dateRange()` berlaku saat parameternya
  sendiri ada (`views_min`, `start_date`); laravel-teorion juga butuh
  parameter yang dideklarasikan itu sendiri.
- Penolakan berupa 400, bukan 500.
