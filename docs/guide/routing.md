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
          final data = request.validated();
          final post = await Post.query().create(data.toMap());
          return PostResource(post).withStatus(201);
        })
        .name('posts.store')
        .validates(const StorePostRequest())
        .returns(PostResource.schema, name: 'Post');
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

## Declared validation and responses

A route can declare its input and output, so the kernel validates before the
handler runs and `dartisan openapi:generate` documents both:

- `.validates(const StorePostRequest())` runs the form request
  (`authorize()` → 403, rules → 422) before the handler;
  `.rules({'q': 'required|string'})` does the same with inline rules (query
  input for `GET`). The handler reads the result with `request.validated()`,
  which throws when the route declares no validation.
- `.returns(PostResource.schema, name: 'Post', shape: .paginated)` documents
  the response: `item` (`{"data": ...}`), `raw`, `collection`, `paginated`,
  `simplePaginated` or `cursorPaginated`, wrapped in Laravel's resource and
  paginator envelopes. Named schemas become `components.schemas`.
- `.action('PostController@store')` records the controller action
  (`x-daravel-action` in OpenAPI).

`rulesToJsonSchema(rules)` is the conversion used for the request schema:
dotted keys nest, `*` becomes array items, `nullable` adds `null`, and
`min`/`max`/`between`/`size` map to the bound that fits the type.

## Reading input

The query string is in memory from the start, so its typed readers need no
`await`; the body is read once, asynchronously, and validated input is then
available synchronously:

```dart
router.get('/posts', (request) async {
  final page = request.queryInt('page', 1);          // ?page=2 → 2
  final drafts = request.queryBool('drafts');        // on, 1, true, yes
  final q = request.queryString('q');                // '' when missing
  final tags = request.queryInput['tags'];           // ?tags[]=a&tags[]=b → [a, b]
  ...
});

router.post('/posts', (request) async {
  final data = request.validated();                  // after .rules / .validates
  final title = data.string('title');
  final views = data.maybeInteger('views') ?? 0;
  ...
}).rules({'title': 'required|string', 'views': 'nullable|integer'});
```

`queryInt`, `queryDouble`, `queryBool` and `queryString` convert like their
asynchronous counterparts over the whole input (`await request.integer(...)`,
`float`, `boolean`, `string`), accept dot notation (`filter.page`) and see
input transformers such as `TrimStrings`, as Laravel's query bag does.

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
