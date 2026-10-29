<!-- source: routing.md sha256:68aed0385987 -->
# Routing

Route didaftarkan di `routes/api.dart` (di-mount di bawah `/api`) dan
`routes/web.dart`. Handler menerima `Request` dan mengembalikan sebuah nilai:
`Response`, resource, model, map atau list (JSON), string (teks), atau
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

### Route di luar `/api`

Route `api:` dipasang di bawah `apiPrefix` (`/api`). Aplikasi yang API-nya
berada di tempat lain, atau di beberapa root, memasangnya sendiri dengan
`then:`:

```dart
.withRouting(
  web: webRoutes,
  apiPrefix: '',                        // atau jangan isi api:
  then: [
    (router) => router.group(adminV1, prefix: '/admin/v1'),
    (router) => router.group(adminV2, prefix: '/admin/v2'),
    (router) => router.group(mobile, prefix: '/{tenant}/v2'),
  ],
)
```

`Request.current` memberikan request yang sedang ditangani di mana pun
dalam rantai pemanggilannya (sebuah helper, sebuah observer), seperti
`request()` di Laravel; nilainya `null` di luar request.

## Fitur route

- Verb: `get`, `post`, `put`, `patch`, `delete`, `options`, `any`,
  `match([...])`, `redirect`, `permanentRedirect`, `fallback`.
- Parameter: `{id}`, opsional `{id?}`, batasan `whereNumber`,
  `whereAlpha`, `whereUuid`, `whereIn`, `where('slug', regex)`.
- `group(..., prefix:, middleware:, name:)` bisa disarangkan sebebasnya.
- `apiResource('photos', PhotoController())` mendaftarkan `index`, `store`,
  `show`, `update` (PUT dan PATCH), dan `destroy` sebagai `photos/{photo}`,
  dengan nama `photos.index` dan seterusnya, persis seperti Laravel.
- `router.url('posts.show', {'id': 1})` membangun URL dari nama route; URL
  bertanda tangan (signed URL) tersedia untuk middleware `signed`.
- `dart run bin/dartisan.dart route:list` mencetak tabelnya.

Route yang tidak dikenal menjawab `404 {"message": "The route api/x could not
be found."}`. Path yang dikenal dengan verb yang salah menjawab `405` dengan
header `Allow` dan pesan dari Laravel.

## Validasi dan respons yang dideklarasikan

Sebuah route bisa mendeklarasikan input dan output-nya, sehingga kernel
memvalidasi sebelum handler berjalan dan `dartisan openapi:generate`
mendokumentasikan keduanya:

- `.validates(const StorePostRequest())` menjalankan form request
  (`authorize()` → 403, rule → 422) sebelum handler;
  `.rules({'q': 'required|string'})` melakukan hal yang sama dengan rule
  inline (input query untuk `GET`). Handler membaca hasilnya dengan
  `request.validated()`, yang melempar exception bila route tidak
  mendeklarasikan validasi.
- `.returns(PostResource.schema, name: 'Post', shape: .paginated)`
  mendokumentasikan respons: `item` (`{"data": ...}`), `raw`, `collection`,
  `paginated`, `simplePaginated`, atau `cursorPaginated`, dibungkus amplop
  resource dan paginator dari Laravel. Schema bernama menjadi
  `components.schemas`.
- `.action('PostController@store')` mencatat action controller
  (`x-daravel-action` di OpenAPI).

### Referensi API langsung

Secara lokal (`APP_ENV=local`), `GET /docs/api` menyajikan referensi
interaktif untuk setiap route (Scalar, seperti Laravel Scramble atau `/docs`
di FastAPI): path, parameter, schema request dan respons, serta client untuk
mengirim request, dengan bearer token untuk route `auth`.
`GET /docs/api.json` adalah dokumen OpenAPI 3.1 yang sama dengan yang ditulis
`dartisan openapi:generate` (`buildOpenApi`). `API_DOCS=true` menyalakannya
di environment lain dan `API_DOCS=false` mematikannya; `API_DOCS_PATH`
memindahkan path-nya. Halaman ini memuat Scalar dari jsDelivr, jadi browser
butuh akses internet; JSON-nya tidak.

`rulesToJsonSchema(rules)` adalah konversi yang dipakai untuk schema
request: key bertitik menjadi bersarang, `*` menjadi item array, `nullable`
menambahkan `null`, dan `min`/`max`/`between`/`size` dipetakan ke batas
yang sesuai dengan tipenya.

## Membaca input

Query string sudah ada di memori sejak awal, jadi pembaca bertipenya tidak
butuh `await`; body dibaca sekali secara asinkron, lalu input yang sudah
divalidasi tersedia secara sinkron:

```dart
router.get('/posts', (request) async {
  final page = request.queryInt('page', 1);          // ?page=2 → 2
  final drafts = request.queryBool('drafts');        // on, 1, true, yes
  final q = request.queryString('q');                // '' bila tidak ada
  final tags = request.queryInput['tags'];           // ?tags[]=a&tags[]=b → [a, b]
  ...
});

router.post('/posts', (request) async {
  final data = request.validated();                  // setelah .rules / .validates
  final title = data.string('title');
  final views = data.maybeInteger('views') ?? 0;
  ...
}).rules({'title': 'required|string', 'views': 'nullable|integer'});
```

`queryInt`, `queryDouble`, `queryBool`, dan `queryString` mengonversi
seperti padanan asinkronnya atas seluruh input (`await request.integer(...)`,
`float`, `boolean`, `string`), menerima notasi titik (`filter.page`), dan
melihat input transformer seperti `TrimStrings`, sebagaimana query bag
Laravel.

## Middleware

Middleware global dikonfigurasi di `bootstrap/app.dart`
(`withMiddleware((m) => m.use([...]))`), grup dengan `m.group('api', [...])`,
dan per route dengan `.middleware(const ['auth', 'can:update,post'])`.
Urutannya global → grup → route, diurutkan menurut daftar prioritas
middleware.

## Rate limiting

Limiter bernama didefinisikan di `withRateLimits` dan diterapkan dengan
`throttle:<name>`:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#rate-limit -->
```dart
limiter.define(
  'writes',
  (request) => Limit.perMinute(30).by(request.ip),
);
```
<!-- /include -->

Respons membawa `X-RateLimit-Limit` dan `X-RateLimit-Remaining`; request
yang terkena batas mendapat `429 {"message": "Too Many Attempts."}` dengan
`Retry-After` dan `X-RateLimit-Reset`. Batasnya dibagi oleh setiap isolate
dalam proses melalui coordinator. Seperti Laravel, sebuah jendela dimulai
pada hit pertama dan di-reset setelah `decay`. Dengan beberapa isolate, key
dengan batas longgar (32 percobaan atau lebih) dilayani dari lease lokal
kecil yang membesar untuk key yang ramai dan mengembalikan hit yang tidak
terpakai: batasnya tidak pernah terlampaui (hit yang di-lease satu worker
bisa sejenak tidak tersedia bagi worker lain, paling lama 200 ms), dan
coordinator tidak lagi dilibatkan di setiap request.

Fixed window bisa meloloskan sampai dua kali batas di sekitar reset.
`Limit.perMinute(60).slidingWindow()` juga menimbang jendela sebelumnya,
dan `.gcra()` meratakan batasnya (satu percobaan setiap decay / batas,
seluruh batas sebagai burst setelah periode sepi). Keduanya membutuhkan
`CACHE_LIMITER=redis` dengan [daravel_redis](redis.md#algoritma-rate-limit);
store lain menghitungnya sebagai fixed window.
