# Responses and resources

Handlers can return `Response.json(data, status: 201)`, `Response.text`,
`Response.html`, `Response.redirect`, `Response.stream`,
`Response.noContent()`, any `JsonSerializable` or `Responsable`, maps,
lists, models and paginators. Dates serialize like Carbon's `toJSON()`:
UTC with microseconds, `2026-01-02T03:04:05.000000Z`.

## API resources

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#resource -->
```dart
final class PostResource extends JsonResource<Post> {
  PostResource(super.resource);

  /// Documents the item for `dartisan openapi:generate` (`.returns(...)`).
  static const Map<String, Object?> schema = {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer'},
      'title': {'type': 'string'},
      'published': {'type': 'boolean'},
    },
  };

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'title': resource.title,
    'published': resource.published,
  };
}
```
<!-- /include -->

- A single resource is wrapped in `{"data": {...}}`.
- `JsonResource.collection(items, PostResource.new)` wraps lists, and for
  paginators produces Laravel's `{data, links: {first, last, prev, next},
  meta}`, where `meta` is the paginator array without `data` and the URLs.
- `when`, `whenLoaded`, `mergeWhen`, `additional({...})` and
  `withMeta(request)` (Laravel's `with()`) are available.

## HTML

`package:daravel/html.dart` builds pages from Dart functions instead of Blade
templates. Text and attribute values are always escaped; markup that must be
written as is goes through `raw()`, like Blade's `{!! !!}`. A node returned
from a handler is sent as `text/html`:

```dart
import 'package:daravel/html.dart';

HtmlNode userCard(User user) => div(classes: 'card', [
  h2([user.name]),                                   // escaped
  p(classes: 'muted', [user.email]),
  if (user.isAdmin) span(classes: 'badge', ['Admin']),
]);

router.get('/users/{id}', (request) async => document(title: 'Profile', [
  mainEl([userCard(await User.query().findOrFail(request.param<int>('id')))]),
]));
```

Children are nodes, strings (escaped text), numbers, `null` (skipped) and
nested lists, so `if` and `for` work inside them. There are helpers for the
common elements (`div`, `span`, `p`, `h1`–`h3`, `a`, `ul`/`ol`/`li`, tables,
`form`, `input`, `label`, `button`, `img`, …), `el(tag, ...)` for any other,
and attributes where `true` writes a bare attribute (`required`) and
`false`/`null` leave it out. It is a separate import because names such as
`a`, `p` and `text` would clash with ordinary variables.

## Errors

Exceptions are rendered by the exception handler with Laravel's bodies. With
`APP_DEBUG=false` nothing internal leaks:

| Situation | Status | `message` |
| :-- | :-- | :-- |
| Validation failed | 422 | first error + `(and N more errors)`, plus `errors` |
| Not authenticated | 401 | `Unauthenticated.` |
| Gate / policy denied | 403 | `This action is unauthorized.` |
| Unknown route | 404 | `The route api/x could not be found.` |
| `findOrFail` / `firstOrFail` | 404 | `No query results for model [App\Models\Post] 1` |
| Wrong verb | 405 | `The DELETE method is not supported for route ... Supported methods: GET, HEAD.` |
| Body too large | 413 | `The POST data is too large.` |
| Rate limited | 429 | `Too Many Attempts.` |
| `abort(404)` without message | 404 | empty string, like Laravel |
| Anything else | 500 | `Server Error` |

Register custom renderers with `withExceptions((e) => e.render<MyError>((error,
request) => Response.json({...}, status: 409)))`.
