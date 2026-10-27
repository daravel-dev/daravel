# Query filters

`daravel_teorion` turns a listing's query string into filters, eager loads,
counts, sorts and pagination, within whitelists you declare once per model.
It is a port of [laravel-teorion](https://packagist.org/packages/teoprayoga/laravel-teorion)
with its request format, so one client works against a Laravel and a
Daravel API alike.

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

`make:query-filter` registers it in `bootstrap/query_filters.dart`; give
that map to the application, and a controller is one line:

```dart
Application.configure(basePath: basePath).withQueryFilters(queryFilters)

router.get('/posts', (request) => Post.definition.query().filterAndPaginate(request));
router.get('/posts/{id}', (request) =>
    Post.definition.query().findFiltered(request, request.param<String>('id')));
```

A model can name its filter instead (`with Filterable<Post>` and
`newQueryFilter()`), and any call can pass one:
`filterAndPaginate(request, AdminPostQueryFilter())`. `filter(request)`
returns the query, to go on with `.where(...)`, `.get()` or `.first()`.

## The request

| Parameter | Example | Effect |
| :-- | :-- | :-- |
| A declared filter | `?q=dart&status=published` | Applied when present (or with its default) |
| `scopes[]` | `?scopes[]=published` | The model's scope, given the whole request |
| `scopes[N]` | `?scopes[0][name]=byAuthor&scopes[0][params][author_id]=3` | The scope, given only its own parameters |
| `withs[]` | `?withs[]=author&withs[]=tags` | Eager loads (each path must be listed in `allowedWiths`) |
| `withs[]` with columns | `?withs[]=author:id,name` | Only those columns, when `allowedWithColumns` lists them |
| `withCounts[]` | `?withCounts[]=comments` | `comments_count` |
| `withAggregates` | `?withAggregates[comments][sum][]=score` | `comments_sum_score` (also `avg`, `min`, `max`, `count`) |
| `sort` | `?sort=-created_at,title` | `-` for descending |
| `order[N]`, `order_by` | `?order_by=title&order_direction=desc` | The legacy formats |
| `order_null_bottoms[]` | `?order_null_bottoms[]=published_at` | NULLs last |
| `is_paginate`, `per_page` | `?is_paginate=1&per_page=20` | A page (`LengthAwarePaginator`) instead of every row |
| `pagination=cursor`, `cursor` | `?pagination=cursor&per_page=20` | A `CursorPaginator` |
| `max_results` | `?max_results=5` | At most that many rows, without paging |
| `with_trashed`, `only_trashed` | `?with_trashed=1` | On soft-deleting models |
| `visibles[]`, `hiddens[]` | `?hiddens[]=email` | Hides attributes, or shows hidden ones you list in `allowedVisibles` |

Without `is_paginate` or `pagination`, every matching row comes back, as in
laravel-teorion (10 per page by default once paging, `TEORION_DEFAULT_PER_PAGE`).
`per_page` and `max_results` are capped at `TEORION_MAX_PER_PAGE` (100, the
`max:100` of the validation rules); a value below 1 means the default.

A sort column or scope outside its whitelist answers 400 with
laravel-teorion's message (`Sort column [password] is not in the allowed
sorts list.`), as does a required filter that is missing. Relations outside
`allowedWiths`, which lists full paths (`author` does not open
`author.posts`), hidden attributes outside `allowedVisibles` (none by
default: laravel-teorion lets a client un-hide anything, Daravel does not),
and allowed scopes the model does not define, are skipped, unless
`TEORION_STRICT` (`APP_DEBUG` by default) refuses them too.

A client picks a relation's columns only among those you list, by relation
path; a relation without a list is loaded whole and asking it for columns
is refused, as is any other column (`Column [password] of relation [author]
is not in the allowed with columns list.` in strict mode). The keys the
relation matches on are added, so `author:name` still finds its author.

```dart
@override
Map<String, List<String>> get allowedWithColumns => {
  'author': ['id', 'name', 'avatar'],
  'author.country': ['name'],
};
```

## Filters

| Filter | SQL |
| :-- | :-- |
| `Filter.exact()` | `col = ?` |
| `Filter.like()`, `Filter.multiLike([...])` | `col LIKE %?%`, `(a LIKE %?% OR b LIKE %?%)` |
| `Filter.boolean()` | `col = 1` or `0` |
| `Filter.null_()` | `col IS NOT NULL` for a true value, `IS NULL` otherwise |
| `Filter.enum_(col, values)` | `col = ?` for one of `values`; another value matches nothing |
| `Filter.in_()` | `col IN (...)` from `a,b` or `col[]=a&col[]=b` |
| `Filter.date()`, `Filter.dateRange(col, 'start_date', 'end_date')` | `DATE(col) = ?`, `col BETWEEN ? AND ?` |
| `Filter.between()`, `Filter.range()` | `BETWEEN` from `a,b`; `>=`/`<=` from `<param>_min` / `<param>_max` |
| `Filter.gt(col, orEqual)`, `Filter.lt(...)` | `col > ?`, `col < ?` |
| `Filter.has('comments')` | `EXISTS` / `NOT EXISTS` |
| `Filter.jsonContains()` | `whereJsonContains(col, value)` |
| `Filter.callback((query, value, param, request) {...})` | Yours |
| `Filter.scope('name')`, `Filter.macro('name')` | A model scope; a type registered with `FilterMacroRegistry.register` |

Each takes `.alias('q')`, `.withDefault(value)` and `.required()`. The
names with an underscore (`enum_`, `in_`, `null_`) avoid Dart keywords.

## Validation, docs and audit

`PostQueryFilter().validationRules` gives a form request the rules of the
listing parameters and each filter (laravel-teorion's
`HasQueryFilterRules`); `openApiParameters` describes them for an API
reference.

With `TEORION_AUDIT_ENABLED=true`, each listing dispatches `QueryAudited`
with a fingerprint (SHA-256 of the filter, the model and the request's
parameters, their order and the page aside), the terminal mode, the result
count, the duration and the user; `TEORION_AUDIT_LOG` logs it too and
`TEORION_AUDIT_SAMPLE_RATE` audits a share of fingerprints, always the same
ones.

## Differences from laravel-teorion

- `order_null_bottoms[]` takes allowed sort columns only, quoted;
  laravel-teorion writes the value into SQL as it comes.
- `withs[]=relation:columns` takes only the columns `allowedWithColumns`
  lists; laravel-teorion passes any column, hidden ones included.
- `Filter.range()` and `Filter.dateRange()` apply when their own
  parameters are there (`views_min`, `start_date`); laravel-teorion also
  needs the declared parameter itself.
- Refusals are 400 instead of 500.
