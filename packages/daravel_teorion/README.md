<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_teorion

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_teorion/README.id.md)

Request-driven query filters for [Daravel](https://pub.dev/packages/daravel):
a listing's query string becomes filters, eager loads, counts, sorts and
pagination, within whitelists declared once per model. A port of
[laravel-teorion](https://packagist.org/packages/teoprayoga/laravel-teorion)
with its request format, so one client works against a Laravel and a
Daravel API alike.

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

- Seventeen filter types with `alias`, `withDefault` and `required`,
  macros, legacy and isolated scopes, `withs`, `withCounts`,
  `withAggregates`, three sort formats, pages, cursors, soft deletes and
  `visibles` / `hiddens`.
- Validation rules, OpenAPI parameters and a fingerprinted audit event.
- Tested on SQLite, PostgreSQL and MariaDB.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/query-filters.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
