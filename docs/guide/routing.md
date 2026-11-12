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
- `dart run bin/dartisan.dart names:sync` writes `lib/app/names.dart`: a URL
  builder per named route (`Routes.postsShow(post: 1)`, a missing parameter
  does not compile) and `RouteNames`, `Abilities`, `RateLimiters`, `Guards`,
  `Disks` and `Connections`, so the editor lists the application's names.
  It boots the application for inspection: no database connection, no
  metrics publisher, nothing sent; a provider that needs the database at
  boot makes it fail with that reason. `names:sync --check` exits 1 when
  the file is out of date: in CI it needs only what boot needs (a `.env`
  with `APP_KEY` when the application reads it), no running service.
  `names:sync --boot` boots the application fully instead, for a provider
  that needs the database while booting.
  - Parameters: `{post}`, `:id`, `{post:slug}` (named `post`, its dartdoc
    names the column) and the wildcards `{path*}`/`*path` are required
    (the router matches no empty wildcard); `{slug?}` is optional. Each
    builder's dartdoc shows its methods and pattern (`GET /posts/{post}`).
  - Routes are code, so the application must compile: add a route, run
    `names:sync`, then use `Routes.x`. A route removed or renamed makes the
    code using it fail to compile, which is the point.
  - The names come from the application booted with the machine's
    environment: the configured disks, connections and guards, and routes
    or limiters registered only in some environments (only with
    `APP_DEBUG`, say), come and go with it. Run `names:sync` and
    `names:sync --check` with the same environment, for example
    `APP_ENV=testing` in both. A failed `--check` lists the names that
    differ (`Disks -s3`, `Routes +posts.show`).

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
- `.returnsFile(contentType: 'text/csv')` documents a file instead
  (`Response.download`, `Excel.download`, a stream): a binary body with
  `Content-Disposition`. A `raw` response with
  `RouteResponse.binarySchema` counts as a file too. Generated Flutter
  clients return its bytes and file name (`ApiFile`).
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

The aliases can also be written with `Mw`, so the editor lists them and
their parameters and a misspelled alias does not compile:

```dart
r.patch('/posts/{post}', update).middleware([
  Mw.auth(['token']),             // 'auth:token'
  Mw.can('update', ['post']),     // 'can:update,post'
  Mw.throttle('writes'),          // 'throttle:writes'
  Mw.cacheHeaders(noStore: true), // 'cache.headers:no_store'
]);
```

Each token is the alias string itself, so tokens and strings mix in one
list. `Mw` covers the aliases Daravel registers (`auth`, `can`, `throttle`,
`cache.headers`, `feature`, `signed`). The aliases a package registers
(`role`, `permission`, `session`, `csrf`, `teobiefy`, ...) are written as
strings: those packages have no tokens yet.

An exception becomes a response where it was thrown, so outer middleware still
finish and a `try` around `next` catches nothing. Read `response.exception`
instead, as in Laravel.

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
`X-RateLimit-Reset`. `throttle:60,1` (no named limiter) counts per client as
Laravel does: the matched route's domain and the client address, never the
`Host` header the client sends, so every route under that limit on one
domain shares the client's bucket; a named limiter keys by its own
`Limit.by(...)`. Limits are shared by every isolate of the process
through the coordinator. Like Laravel, a window starts with the first hit
and resets `decay` later. With several isolates, keys with generous limits
(32 or more attempts) are served from small local leases that grow on hot
keys and give unused hits back: the limit is never exceeded (a hit leased by
one worker may briefly be unavailable to another, for at most 200 ms, even
when that worker goes quiet), and the coordinator is no longer on every
request: concurrent requests for one key on one worker share a single lease
request.

A fixed window lets up to twice the limit through around a reset.
`Limit.perMinute(60).slidingWindow()` also weighs the previous window, and
`.gcra()` spreads the limit evenly (one attempt every decay / limit, the
whole limit as a burst after a quiet period). Both need
`CACHE_LIMITER=redis` with [daravel_redis](redis.md#rate-limit-algorithms);
other stores count them as a fixed window.

When the coordinator cannot answer in time (an overloaded process, say),
rate limiting fails open: the request goes through uncounted and a warning
is logged (at most once a second, counting the ones it skipped), so a
slow coordinator never takes the site down. The same holds when the cache
store behind `CACHE_LIMITER=database` or `redis` fails: the request goes
through instead of failing with a `500`. A limit that
guards credentials (login, OTP, password reset) should fail closed, so that
flooding the server does not lift it: such a request gets the `429` with
`Retry-After: 1` instead.

```dart
limiter.define(
  'login',
  (request) => Limit.perMinute(5).by(request.ip).failsClosed(),
);
```

`ThrottleMiddleware(failClosed: true)` does the same for every limit of one
middleware, and `ProcessRateLimitStore(failClosed: true)` for the whole
store.

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

## Laravel equivalents

More of Laravel that this works with, and the API to look up on pub.dev.

| Laravel | Daravel | API | Note |
| :-- | :-- | :-- | :-- |
| `Route::match($methods, ...)` | `router.match(methods, path, handler)` | `Router.match` |  |
| `Route::any(...)` | `router.any(path, handler)` | `Router.any` |  |
| `Route::fallback(...)` | `router.fallback(handler)` | `Router.fallback` |  |
| `Route::apiResource('photos', PhotoController::class)` | `router.apiResource('photos', PhotoController())` | `Router.apiResource` |  |
| `->whereUuid('id')` | `.whereUuid('id')` | `RouteEntry.whereUuid` |  |
| `/users/{user}/posts/{post:slug}` | the same path | `RouteEntry.bindingFields` |  |
| `->withTrashed() / ->missing(fn () => ...)` | `.withTrashed() / .missing((request) => ...)` | `RouteEntry.missing` |  |
