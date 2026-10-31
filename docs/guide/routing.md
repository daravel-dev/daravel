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

### Routes outside `/api`

`api:` routes are mounted under `apiPrefix` (`/api`). An application whose
API lives elsewhere, or in several roots, mounts them itself with `then:`:

```dart
.withRouting(
  web: webRoutes,
  apiPrefix: '',                        // or leave api: out
  then: [
    (router) => router.group(adminV1, prefix: '/admin/v1'),
    (router) => router.group(adminV2, prefix: '/admin/v2'),
    (router) => router.group(mobile, prefix: '/{tenant}/v2'),
  ],
)
```

`Request.current` gives the request being handled anywhere in its call
chain (a helper, an observer), as Laravel's `request()` does; it is `null`
outside a request.

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

### Live API reference

Locally (`APP_ENV=local`), `GET /docs/api` serves an interactive reference
of every route (Scalar, as Laravel Scramble or FastAPI's `/docs`): paths,
parameters, request and response schemas, and a client to send requests,
with a bearer token for `auth` routes. `GET /docs/api.json` is the same
OpenAPI 3.1 document `dartisan openapi:generate` writes (`buildOpenApi`).
`API_DOCS=true` turns it on in another environment and `API_DOCS=false`
off; `API_DOCS_PATH` moves it. The page loads Scalar from jsDelivr, so the
browser needs internet access; the JSON does not.

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
`.withoutMiddleware(['csrf'])` takes one off a route, as an alias, a group, a
type or an instance, also when an outer group brought it in.

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

A fixed window lets up to twice the limit through around a reset.
`Limit.perMinute(60).slidingWindow()` also weighs the previous window, and
`.gcra()` spreads the limit evenly (one attempt every decay / limit, the
whole limit as a burst after a quiet period). Both need
`CACHE_LIMITER=redis` with [daravel_redis](redis.md#rate-limit-algorithms);
other stores count them as a fixed window.

## Subdomains

A group or a route can answer on one host only:

```dart
router.group((r) {
  r.get('/', dashboard);
}, domain: 'admin.example.com');

router.group((r) {
  r.get('/exams/{exam}', show).scopeBindings();
}, domain: '{tenant:slug}.example.com');

router.get('/health', health).domain('api.example.com');
```

A parameter is one label and lands in `request.routeParams` before the path's,
so a bound `{tenant}` scopes the models after it. Routes with a domain are tried
first, and the host is matched without its port or case. `router.url()` answers
an absolute URL on that host, with the scheme of the base URL. Behind a proxy,
`TrustProxies` decides which host counts.

## Route model binding

Bind a parameter to a model, explicitly, because a Dart handler has no
parameter types to tell a model from an id:

```dart
router.bindModel('author', Author.definition);
router.bindModel('post', Post.definition);

router.get('/posts/{post}', (request) => request.binding<Post>('post'));
router.get('/blog/{post:slug}', show);                  // by another column
router.get('/authors/{author}/posts/{post}', show).scopeBindings();
```

`scopeBindings()` looks each model up through the relation of the one before
it, so another author's post is a 404. A custom column such as
`{author}/{post:slug}` implies it, as in Laravel; `withoutScopedBindings()`
turns it off, and `router.group(..., scopeBindings: true)` sets it for a group.
Without either, a nested path does not check ownership.

`withTrashed()` also finds soft deleted models, and `missing((request) => ...)`
replaces the 404.
