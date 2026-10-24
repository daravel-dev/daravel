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
