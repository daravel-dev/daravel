<!-- source: README.md sha256:9017f275cd90 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_teorion

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_teorion/README.md) · Bahasa Indonesia

Query filter dari request untuk [Daravel](https://pub.dev/packages/daravel):
query string sebuah listing menjadi filter, eager load, count, sort, dan
pagination, dalam whitelist yang dideklarasikan sekali per model. Port dari
[laravel-teorion](https://packagist.org/packages/teoprayoga/laravel-teorion)
dengan format request yang sama, sehingga satu client bisa dipakai untuk
API Laravel maupun Daravel.

```bash
dart pub add daravel_teorion
dartisan make:query-filter Post
```

```dart
final class PostQueryFilter extends QueryFilter<Post> {
  @override
  Map<String, Filter> get filters => {
    'search': Filter.multiLike(['title', 'body']).alias('q'),
    'status': Filter.enum_('status', PostStatus.values),
  };

  @override
  List<String> get allowedSorts => ['created_at', 'title'];
}

router.get('/posts', (request) => Post.definition.query().filterAndPaginate(request));
```

```text
GET /posts?q=dart&withs[]=author&sort=-created_at&is_paginate=1&per_page=20
```

- Tujuh belas tipe filter dengan `alias`, `withDefault`, dan `required`,
  macro, scope lama maupun terisolasi, `withs`, `withCounts`,
  `withAggregates`, tiga format sort, halaman, cursor, soft delete, serta
  `visibles` / `hiddens`.
- Aturan validasi, parameter OpenAPI, dan event audit ber-fingerprint.
- Diuji di SQLite, PostgreSQL, dan MariaDB.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/query-filters.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak berafiliasi
dengan dan tidak didukung oleh keduanya.
