# Routing

Routes are registered in `routes/api.dart` (mounted under `/api`) and
`routes/web.dart`. A handler receives the `Request` and returns a value:
a `Response`, a resource, a model, a map or list (JSON), a string (text) or
`null` (204).

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#routing -->
```dart
void apiRoutes(Router router) {
  router
      .get('/posts', (request) async {
        final page = await Post.query().scope('published').latest().paginate();
        return JsonResource.collection(page, PostResource.new);
      })
      .name('posts.index');

  router
      .get('/posts/{id}', (request) async {
        final post = await Post.query().findOrFail(request.param<int>('id'));
        return PostResource(post);
      })
      .name('posts.show')
      .whereNumber('id');

  router.group((router) {
    router
        .post('/posts', (request) async {
          final data = await FormRequest.run(const StorePostRequest(), request);
          final post = await Post.query().create(data.toMap());
          return PostResource(post).withStatus(201);
        })
        .name('posts.store');
  }, middleware: const ['auth', 'throttle:writes']);
}
```
<!-- /include -->

## Route features

- Verbs: `get`, `post`, `put`, `patch`, `delete`, `options`, `any`,
  `match([...])`, `redirect`, `permanentRedirect`, `fallback`.
- Parameters: `{id}`, optional `{id?}`, constraints `whereNumber`,
  `whereAlpha`, `whereUuid`, `whereIn`, `where('slug', regex)`.
- `group(..., prefix:, middleware:, name:)` nests freely.
- `apiResource('photos', PhotoController())` registers `index`, `store`,
  `show`, `update` (PUT and PATCH) and `destroy` as `photos/{photo}`, named
  `photos.index` and so on, exactly like Laravel.
- `router.url('posts.show', {'id': 1})` builds URLs from names; signed URLs
  are available for the `signed` middleware.
- `dart run bin/dartisan.dart route:list` prints the table.

Unknown routes answer `404 {"message": "The route api/x could not be
found."}`. A known path with the wrong verb answers `405` with an `Allow`
header and Laravel's message.

## Middleware

Global middleware is configured in `bootstrap/app.dart`
(`withMiddleware((m) => m.use([...]))`), groups with `m.group('api', [...])`,
and routes with `.middleware(const ['auth', 'can:update,post'])`. The order
is global → group → route, sorted by the middleware priority list.

## Rate limiting

Named limiters are defined in `withRateLimits` and applied with
`throttle:<name>`:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#rate-limit -->
```dart
limiter.define(
  'writes',
  (request) => Limit.perMinute(30).by(request.ip),
);
```
<!-- /include -->

Responses carry `X-RateLimit-Limit` and `X-RateLimit-Remaining`; a limited
request gets `429 {"message": "Too Many Attempts."}` with `Retry-After` and
`X-RateLimit-Reset`. Limits are shared by every isolate of the process
through the coordinator. Like Laravel, a window starts with the first hit
and resets `decay` later. With several isolates, keys with generous limits
(32 or more attempts) are served from small local leases that grow on hot
keys and give unused hits back: the limit is never exceeded (a hit leased by
one worker may briefly be unavailable to another, for at most 200 ms), and
the coordinator is no longer on every request.
