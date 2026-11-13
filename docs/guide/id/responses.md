<!-- source: responses.md sha256:3cbd472039d8 -->
# Respons dan resource

Handler bisa mengembalikan `Response.json(data, status: 201)`,
`Response.text`, `Response.html`, `Response.redirect`, `Response.stream`,
`Response.noContent()`, `JsonSerializable` atau `Responsable` apa pun, map,
list, model, dan paginator. Tanggal diserialisasi seperti `toJSON()` dari
Carbon: UTC dengan mikrodetik, `2026-01-02T03:04:05.000000Z`.

`Response.json(data, phpCompatible: true)` menulis byte `json_encode()` PHP
sebagai gantinya: `/` menjadi `\/`, karakter non-ASCII menjadi escape `\u`,
dan map kosong menjadi `[]` (array PHP kosong). Objek yang harus tetap
`{}` saat kosong, seperti `(object) []` di PHP, ditulis sebagai
`PhpObject('stdClass', {...})`. Pakai opsi ini saat client membandingkan
atau menandatangani body yang dulu dikirim endpoint Laravel.

## Cookie

```dart
final theme = request.cookie('theme', 'light');
return Response.json({'theme': theme})
    .withCookie('theme', 'dark', maxAge: const Duration(days: 30))
    .withoutCookie('legacy');
```

`request.cookies` berisi semua cookie, di-decode seperti `$_COOKIE` di PHP.
`withCookie` menambahkan header `Set-Cookie` dengan format yang dikirim
Laravel, dengan default Laravel (`path=/`, `httponly`, `samesite=lax`);
tanpa `maxAge`, cookie berlaku selama sesi browser. Nilai dikirim apa
adanya: middleware `EncryptCookies` dari Laravel belum punya padanan,
sehingga cookie yang dienkripsi Laravel terbaca sebagai payload
terenkripsinya.

## API resource

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

- Resource tunggal dibungkus dalam `{"data": {...}}`.
- `JsonResource.collection(items, PostResource.new)` membungkus list, dan
  untuk paginator menghasilkan `{data, links: {first, last, prev, next},
  meta}` dari Laravel, dengan `meta` berisi array paginator tanpa `data` dan
  URL-nya.
- `when`, `whenLoaded`, `mergeWhen`, `additional({...})`, dan
  `withMeta(request)` (`with()` dari Laravel) tersedia.

### JSON:API

`JsonApiResource` menulis bentuk JSON:API v1.1 yang sama dengan Laravel 13, dengan
content type `application/vnd.api+json`.

```dart
final class PostResource extends JsonApiResource<Post> {
  PostResource(super.resource);

  @override
  String toType(Request? request) => 'posts';

  @override
  Map<String, Object?> toArray(Request? request) => {'title': resource.title};

  @override
  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) => {
    'author': JsonApiRelationship<User>(UserResource.new),
  };
}

router.get('/posts/{post}', (Request request) async {
  return PostResource((await Post.find(request.param('post')))!);
});

router.get('/posts', (Request request) async {
  return JsonApiResource.collection<Post>(
    await Post.query().paginate(perPage: 20),
    PostResource.new,
  );
});
```

`?fields[posts]=title` mempersempit attribute, dan `?include=author,comments.user`
menambahkan relationship dan `included`. Relationship hanya muncul kalau diminta,
dan nama yang tidak dikenal diabaikan, seperti di Laravel. Untuk resource yang
dikembalikan route, kernel memuat yang diminta query sebelum menulis response, per
halaman. Kalau dipanggil di tempat lain, yang belum dimuat tidak disertakan.

`toType` tidak punya default, karena menamainya dari nama class butuh reflection.
`toId` default-nya primary key model. `toLinks` dan `toMeta` menambahkan member itu,
dan `JsonApiResource.configure(version: '1.1')` menambahkan `jsonapi`.
`maxRelationshipDepth` membatasi kedalaman `include`, default 5.

### JSON Schema

`JsonSchema` membangun dokumen schema, seperti `Illuminate\JsonSchema` di Laravel.

```dart
final schema = JsonSchema.object({
  'name': JsonSchema.string().required().max(255),
  'age': JsonSchema.integer().min(0).nullable(),
  'tags': JsonSchema.array().items(JsonSchema.string()),
}).withoutAdditionalProperties();

schema.toArray();
```

`default` dan `enum` adalah kata kunci Dart, jadi namanya `defaultTo` dan
`enumValues`.

## HTML

`package:daravel/html.dart` membangun halaman dari fungsi Dart, bukan dari
template Blade. Teks dan nilai atribut selalu di-escape; markup yang harus
ditulis apa adanya melewati `raw()`, seperti `{!! !!}` di Blade. Node yang
dikembalikan handler dikirim sebagai `text/html`:

```dart
import 'package:daravel/html.dart';

HtmlNode userCard(User user) => div(classes: 'card', [
  h2([user.name]),                                   // di-escape
  p(classes: 'muted', [user.email]),
  if (user.isAdmin) span(classes: 'badge', ['Admin']),
]);

router.get('/users/{id}', (request) async => document(title: 'Profile', [
  mainEl([userCard(await User.query().findOrFail(request.param<int>('id')))]),
]));
```

Child berupa node, string (teks yang di-escape), angka, `null` (dilewati),
dan list bersarang, sehingga `if` dan `for` bisa dipakai di dalamnya. Ada
helper untuk elemen umum (`div`, `span`, `p`, `h1`–`h3`, `a`,
`ul`/`ol`/`li`, tabel, `form`, `input`, `label`, `button`, `img`, `meta`,
`link`, `br`, `hr`, …), `el(tag, ...)` untuk elemen lain, dan atribut dengan
`true` menulis atribut tanpa nilai (`required`) serta `false`/`null`
menghilangkannya. Setiap helper elemen menerima `id`, `classes`, dan
`attributes`, dan `attributes` ditulis paling akhir, sehingga
`link(rel: 'stylesheet', href: ..., attributes: {'integrity': ...})` atau
`tbody(id: 'rows', [...])` tidak perlu `el()`. Import-nya terpisah karena
nama seperti `a`, `p`, dan `text` akan bentrok dengan variabel biasa.
`escapeHtml` (`e()` dari Laravel) diekspor oleh
`package:daravel/daravel.dart` dan `package:daravel/html.dart` sebagai satu
deklarasi yang sama, jadi satu file bisa meng-import keduanya.

`script(src: '/js/app.js', defer: true)` menulis script eksternal
(`module: true` menulis `type="module"`, dan `nonce`, `integrity`, serta
`crossorigin` juga tersedia sebagai parameter). `script(content: ...)` dan
`style(css)` menulis kode inline apa adanya, tanpa escape, jadi isinya harus
kode tepercaya; `</script` atau `</style` di dalamnya ditulis `<\/script`
(`<\/style`) sehingga tidak bisa menutup elemen. Untuk memberikan data ke
script, jangan menyisipkannya ke `content`: `jsonScript(data, id: 'props')`
menulis `<script type="application/json">` dengan `<`, `>`, dan `&`
di-escape, yang dibaca halaman dengan
`JSON.parse(document.getElementById('props').textContent)`.

### Layout dan komponen

`@extends`/`@yield` dan komponen `<x-card>` dengan slot dari Blade cukup
ditulis sebagai fungsi biasa: layout menerima satu parameter untuk setiap
bagian yang di-yield, dan komponen menerima satu parameter untuk setiap slot
(slot default adalah `body`):

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#html-layout -->
```dart
/// The site layout (Blade's `@extends('layouts.app')`): every `@yield` and
/// `@stack` is a parameter, and `body` is the default slot.
HtmlDocument appLayout({
  required String title,
  required List<Object?> body,
  List<Object?> head = const [],
  List<Object?> scripts = const [],
  String? csrfToken,
}) => document(
  title: '$title | Example',
  head: [
    link(rel: 'stylesheet', href: '/css/app.css'),
    ...head,
  ],
  // htmx sends these headers with every request from the page.
  bodyAttributes: {
    if (csrfToken != null)
      'hx-headers': jsonEncode({'X-CSRF-TOKEN': csrfToken}),
  },
  [
    header(classes: 'topbar', [
      a(['Home'], href: '/'),
    ]),
    mainEl(id: 'content', body),
    script(src: '/js/htmx.min.js', defer: true),
    ...scripts,
  ],
);

/// A component with named slots (Blade's `<x-card>` with `$title`, the
/// default slot and `<x-slot:actions>`).
Element card({
  required Object? title,
  required List<Object?> body,
  List<Object?>? actions,
}) => article(classes: 'card', [
  h2(classes: 'card-title', [title]),
  div(classes: 'card-body', body),
  if (actions != null) footer(classes: 'card-actions', actions),
]);
```
<!-- /include -->

Sebuah halaman lalu cukup ditulis
`appLayout(title: 'Posts', body: [card(title: ..., body: [...])])`.
`document(bodyAttributes: {...})` mengatur atribut `<body>`.

### htmx

Request htmx mengirim `HX-Request: true`, dan `package:daravel/html.dart`
membacanya sebagai `request.isHtmx` (beserta `isHtmxBoosted`, `htmxTarget`,
dan `htmxTrigger`). Handler menjawab request htmx dengan fragment yang akan
di-swap, berupa `HtmlNode` apa pun, dan menjawab browser dengan halaman
utuh:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#htmx -->
```dart
Element postRow(Post post) => tr(id: 'post-${post.id}', [
  td([post.title]),
  td([
    if (post.published)
      'Published'
    else
      button(
        ['Publish'],
        attributes: {
          'hx-post': '/posts/${post.id}/publish',
          'hx-target': 'closest tr',
          'hx-swap': 'outerHTML',
        },
      ),
  ]),
]);

void webRoutes(Router router) {
  router.get('/posts', (request) async {
    final rows = tbody(id: 'posts', [
      for (final post in await Post.query().get()) postRow(post),
    ]);
    // htmx asks for the rows only; a browser gets the whole page.
    if (request.isHtmx) {
      return rows;
    }
    return appLayout(
      title: 'Posts',
      body: [
        card(
          title: 'Posts',
          body: [
            table([rows]),
          ],
        ),
      ],
    );
  });

  // The answer is the fragment htmx swaps in: the updated row.
  router.post('/posts/{id}/publish', (request) async {
    final post = await Post.query().findOrFail(request.param<int>('id'));
    await post.update({'published': true});
    return postRow(post);
  });

  // `HX-Redirect` for htmx (which would swap a followed 302 into the
  // target), an ordinary 303 for a plain form.
  router.post('/posts/clear', (request) async {
    await Post.query().delete();
    return htmxRedirect(request, '/posts', status: 303);
  });
}
```
<!-- /include -->

- **Redirect.** Browser mengikuti `302` di dalam request htmx, lalu htmx
  men-swap halaman tujuannya ke dalam target. `htmxRedirect(request, url)`
  menjawab request htmx dengan `200` dan `HX-Redirect: url`, yang diubah
  htmx menjadi pemuatan halaman penuh, dan menjawab request lain dengan
  redirect biasa (berikan `status: 303` setelah `PUT`, `PATCH`, atau
  `DELETE`).
- **CSRF.** Dengan [session](sessions.md#csrf), `POST`, `PUT`, `PATCH`, dan
  `DELETE` memerlukan token. Taruh token di `hx-headers` pada `<body>`, yang
  dikirim htmx bersama setiap request dari halaman tersebut:
  `appLayout(csrfToken: request.session.token, ...)` di atas menulis
  `<body hx-headers='{"X-CSRF-TOKEN": "..."}'>`.

## Caching dan kompresi

Middleware `cache.headers` dari Laravel memasang `Cache-Control`, `ETag`,
dan `Last-Modified` pada respons `GET`/`HEAD` yang sukses, dan menjawab
`304 Not Modified` bila salinan di client masih terbaru:

```dart
router.get('/catalog', catalog).middleware(const [
  'cache.headers:public;max_age=3600;etag',
]);
```

Opsinya sama dengan Laravel (`public`, `private`, `max_age`, `s_maxage`,
`must_revalidate`, `no_cache`, `no_store`, `immutable`, `etag`,
`last_modified=<waktu unix atau tanggal>`, ...) dan header-nya keluar
seperti yang ditulis Laravel (`Cache-Control: max-age=3600, public`;
`private` ditambahkan bila tidak ada `public`, `private`, maupun
`s_maxage`). `etag` meng-hash body (MD5; Laravel memakai xxh128, jadi
nilainya berbeda tetapi perilakunya sama). `If-None-Match` dicocokkan secara
persis, lemah (`W/`), dari sebuah list, atau dengan `*`; `If-Modified-Since`
hanya dipakai tanpa header itu.

`CompressResponseMiddleware` meng-gzip body minimal 1 KB bertipe teks, JSON,
XML, SVG, atau JavaScript untuk client yang mengirim `Accept-Encoding: gzip`
(JSON biasanya menyusut 70–90%), memasang `Vary: Accept-Encoding`, dan
mengubah `ETag` kuat menjadi lemah. Stream dibiarkan. Di belakang proxy yang
sudah mengompresi (`encode` di Caddy, `gzip` di nginx), jangan pakai
middleware ini.

```dart
.withMiddleware((middleware) {
  middleware.use(const [CompressResponseMiddleware()]);
})
```

## Streaming array JSON besar

`Response.streamJson` adalah `response()->streamJson()` dari Laravel: item
sebuah stream dikirim sebagai satu array JSON, di-encode begitu tiba,
sehingga laporan ribuan baris tidak pernah ditahan utuh di isolate.
Byte-nya persis yang ditulis `Response.json` untuk list yang sudah
dikumpulkan, jadi klien tidak perlu berubah; `wrap: 'data'` menaruh array di
bawah sebuah key (`{"data":[...]}`) dan `phpCompatible: true` menulis byte
`json_encode()` PHP. `QueryBuilder.streamJson()` melakukan hal yang sama
langsung dari query, tanpa membangun model: baris dibaca per halaman
`chunk` (500) seperti `lazy()`, jadi beri `orderBy` pada query.

```dart
r.get('/users/export', (req) => Response.streamJson(
  DB.table('users').select(['id', 'name', 'email']).orderBy('id').lazy(),
  wrap: 'data',
));

// Byte yang sama, dari query builder.
r.get('/users/export', (req) => Response.stream(
  DB.table('users').orderBy('id').streamJson(),
  contentType: 'application/json',
));
```

Streaming membatasi memori, bukan CPU: baris tetap di-decode dan di-encode
(1.000 baris × 40 kolom memakan 30 ms saat di-stream, dibanding 23 ms untuk
`get()` plus `Response.json`, AOT, SQLite). Gunakan untuk response yang
terlalu besar untuk ditahan, atau yang perlu mulai dibaca klien sebelum
query halaman terakhir berjalan; gunakan paginasi bila memungkinkan.

## Server-sent events dan WebSocket

`Response.sse` adalah `response()->eventStream()` dari Laravel: setiap item
stream dikirim begitu dihasilkan. Nilai biasa menjadi event `update` (JSON,
kecuali berupa string atau angka), dan `SseEvent` menetapkan nama event,
`id`, dan `retry`. Saat stream berakhir, `</stream>` dikirim seperti di
Laravel, atau berikan `endStreamWith: null` agar tidak mengirim apa pun.

```dart
r.get('/api/orders/{id}/status', (request) async {
  final id = request.param<int>('id');
  return Response.sse(
    Stream.periodic(const Duration(seconds: 2), (_) => id)
        .asyncMap((id) async => (await Order.find(id))?.toJson())
        .take(30),
  );
});
```

Frame-nya sama dengan Laravel (`event: update`, `data: ...`), jadi client
yang ditulis untuk salah satu backend bekerja dengan keduanya. Selain itu:

- Komentar `: keep-alive` dikirim setiap 15 detik selama stream diam
  (`heartbeat:`), agar proxy tetap membuka koneksi. Penulisan itu juga cara
  mendeteksi tab yang sudah ditutup, karena TCP tidak melaporkan apa pun pada
  koneksi yang diam. Stream sumber kemudian dibatalkan.
- `x-accel-buffering: no` dan penulisan tanpa buffer mencegah nginx dan
  `dart:io` menahan event.
- Saat shutdown (SIGTERM, `ServerEngine.stop`), stream yang terbuka
  diakhiri dengan event penutupnya alih-alih menahan shutdown sampai
  timeout, dan `EventSource` tersambung ulang ke instance lain. Baca
  `request.header('last-event-id')` untuk melanjutkan dari `id` terakhir yang
  diterimanya.
- Client yang berhenti membaca (tab yang di-pause, ponsel di jaringan buruk)
  tidak diantrekan tanpa batas: sumber dibaca secepat ia menghasilkan, dan
  begitu lebih dari `maxBufferedBytes` (1 MiB) menunggu client, stream
  diakhiri dengan `retry: 1000` alih-alih event penutupnya dan sumber
  dibatalkan, sehingga `EventSource` tersambung ulang sedetik kemudian. Beri
  `maxBufferedBytes: null` untuk mem-pause sumber selama client tertinggal,
  untuk generator yang menghormati pause.

`router.ws` meng-upgrade koneksi menjadi WebSocket setelah middleware route
lolos. `auth`, `throttle`, dan parameter route bekerja seperti di route mana
pun, dan handler berjalan di scope request, jadi `Auth.user()` bisa dipakai
di sana:

```dart
r.ws('/ws/rooms/{room}', (socket, request) async {
  final room = request.param<String>('room');
  socket.add(jsonEncode({'joined': room, 'user': await Auth.id()}));
  socket.listen((message) => socket.add('echo: $message'));
}).middleware(['auth:sanctum']);
```

Request HTTP biasa ke path itu mendapat `426 Upgrade Required`. Saat
shutdown, socket yang terbuka ditutup dengan `1001` (going away). Ini
WebSocket mentah; Laravel Echo terhubung melalui
[Broadcasting](broadcasting.md). Client yang meminta permessage-deflate
mendapatkannya; `r.ws(path, handler, compress: false)` mematikannya, yang
menghemat CPU dan memori per koneksi saat satu pesan dikirim ke banyak
socket.

Server hanya tahu client pergi selama ada yang mendengarkan socket-nya.
Dengarkan sebelum handler kembali, atau paling lambat 5 detik sesudahnya:
handler boleh kembali lalu mendengarkan begitu persiapannya selesai. Bila
5 detik sesudah handler kembali belum ada yang mendengarkan, server
mendengarkan sendiri dan membuang yang dikirim client, sehingga close atau
kepergian client tetap mengakhiri sesi. Yang sudah dikirim client
sebelumnya dan belum dibaca siapa pun ikut dibuang saat itu. `listen`
sesudah itu mengambil alih pembacaan dan menerima yang tiba sejak saat
itu; sesudah client menutup, ia hanya menerima akhirnya.

Selama belum ada yang mendengarkan, server tetap membaca client dan
menahan yang dikirimnya, berurutan, untuk pendengar yang akan datang:
sampai 64 KiB (atau `maxPayloadBytes` rute, bila lebih kecil) ditambah
satu pesan; sesudah itu TCP menahan client. Jadi handler yang menunggu
`socket.done` tanpa mendengarkan, atau yang menulis dalam loop selama
`socket.readyState == WebSocket.open`, tetap tahu client menutup atau
pergi: 5 detik sesudahnya sesi berakhir, `socket.closeCode` berisi kode
client (1006 bila ia pergi tanpa close), dan yang tertahan dibuang. Client
yang lebih dulu mengirim melebihi batas itu lalu pergi diam-diam tidak
terlihat pergi, dan sesinya bertahan sampai server berhenti. Dengarkan bila
bisa, dengan `socket.listen((_) {})` bila pesannya tidak penting.

Begitu ada yang mendengarkan, tidak ada yang dibuang: pendengar yang
menjeda (`await for` yang lama mengerjakan tiap pesan) menerima semua pesan
lalu close-nya saat ia membaca lagi, berapa pun lamanya; pendengar yang
tidak pernah membaca lagi mempertahankan sesinya, seperti pembaca yang
macet selama ini. Pesan terfragmentasi yang masih tiba saat server menahan
client (lebih dari batas di atas menunggu) tetap menjalankan
`assembleTimeout`-nya.

Apa yang menunggu dikirim di WebSocket dihitung. Client yang membaca lebih
lambat daripada server menulis membuat `dart:io` mengantrekan setiap frame
di memori; begitu lebih dari `maxBufferedBytes` (4 MiB) menunggu, antrean
dibuang dan socket ditutup dengan `1008` (`slowClientCode:`), lalu client
tersambung ulang. Frame yang ditambahkan setelah socket mulai ditutup
dibuang alih-alih melempar error. `realtime_slow_clients_total`
(`transport`: `websocket`, `sse`) menghitung client ini di `/metrics`.

Keduanya butuh koneksi sungguhan. `TestClient` mengumpulkan respons secara
utuh, jadi uji `Response.sse` yang berhingga dengannya, dan uji WebSocket
dengan `ServerEngine` di port 0 dan `WebSocket.connect`.

### Broadcast ke semua isolate

Dengan beberapa isolate, socket seorang user dipegang salah satunya,
sementara request yang membawa kabar untuk user itu bisa berjalan di isolate
lain. `Broadcast` menerbitkan pesan ke sebuah channel dan setiap isolate
mengantarkannya ke listener miliknya sendiri, melalui coordinator, tanpa
Redis:

```dart
r.ws('/ws/orders/{id}', (socket, request) =>
    Broadcast.pipe(socket, ['orders.${request.param<int>('id')}']));

// Di mana saja: controller, job, listener.
await Broadcast.publish('orders.7', {'status': 'shipped'});
```

`pipe` meneruskan sebuah channel ke socket sampai socket ditutup.
`subscribe` memberikan pesannya sebagai stream, untuk SSE atau keperluan
lain:

```dart
r.get('/orders/{id}/events', (request) async {
  final updates = await Broadcast.subscribe('orders.${request.param<int>('id')}');
  return Response.sse(updates.messages);
});
```

Pesan berupa string, atau apa pun selain itu sebagai JSON. Pesan hanya
sampai ke isolate yang punya listener di channel itu, sesuai urutan
terbitnya, dan tidak disimpan: listener menerima apa yang diterbitkan
setelah `subscribe` selesai. Pesan tetap di satu server; untuk beberapa
mesin, terbitkan lewat sesuatu yang dipakai bersama, seperti tabel database
atau queue.

Untuk client Laravel Echo, event dikirim melalui protokol Pusher
([Broadcasting](broadcasting.md)), yang berjalan di atas channel-channel
ini.

## File

```dart
return Response.download('storage/report.xlsx', name: 'Report.xlsx');
return Response.download(tmp, deleteFileAfterSend: true);
return Response.file('storage/manual.pdf', request: request);

return Storage.download('reports/q3.pdf', request: request);
return Storage.disk('s3').response('videos/intro.mp4', request: request);
```

`download` menjawab sebagai attachment dan `file` menampilkan file di browser,
dengan tipe dari namanya, `ETag`, dan `Last-Modified`. Nama file yang bukan ASCII
biasa mendapat `filename*`, dan nama berisi path atau karakter kontrol adalah
error. File yang tidak ada menjadi 404.

Kirim `request` untuk `Range`: 206 untuk satu range, 416 jika melewati akhir file,
seperti yang dibutuhkan penampil PDF dan pemutar iOS, serta 304 untuk
`If-None-Match`. Request dengan beberapa range menerima file utuh.
`deleteFileAfterSend` menghapus file setelah terkirim dan tidak menawarkan range,
karena range kecil pertama dari penampil akan menghapusnya.

Disk membaca dari awal untuk mencapai sebuah range, yang di S3 berarti mengunduh
bagian sebelumnya. Jangan menyusun path `Response.file` dari input pengguna; disk
memeriksa path-nya sendiri.

### Konten yang dibuat untuk request

File yang tidak pernah ada di disk, dibuat untuk request ini, diunduh tanpa
ditulis lebih dulu:

```dart
return Response.downloadBytes(utf8.encode(plist), name: 'exam.seb');

return Response.streamDownload(            // streamDownload dari Laravel
  DB.table('orders').lazy().map((row) => utf8.encode(csvLine(row))),
  name: 'orders.csv',
);
```

Keduanya mengambil tipe dari nama (`text/csv`), atau
`application/octet-stream`, kecuali `contentType` menentukan lain, dan mengirim
`Content-Disposition` yang ditulis `contentDisposition(name)` (juga diekspor,
untuk respons yang disusun sendiri). `downloadBytes` menyimpan byte-nya.
`streamDownload` menulis stream selagi dihasilkan: klien yang pergi
membatalkannya, sehingga produsen `async*` berhenti di `yield` berikutnya, dan
request `HEAD` mendapat header tanpa memulainya.

## File statis

Laravel menyerahkan `public/` ke web server. Aplikasi Daravel adalah web server
itu sendiri, jadi aplikasi menyajikan direktori tersebut sendiri:

```dart
Application.configure(basePath: basePath)
    .withStatic('public', prefix: '/assets')
```

```dart
Response.html('<link rel="stylesheet" href="${asset('neo.css')}">');
// <link rel="stylesheet" href="/assets/neo.css?v=1a2b3c4d5e6f">
```

`asset(path)` menambahkan 12 digit hex pertama dari SHA-256 file. Request yang
membawa versi terkini dijawab dengan
`Cache-Control: public, max-age=31536000, immutable`; tanpa versi, atau dengan
versi lama, dengan `public, max-age=300` (`maxAge:`). `ETag`, 304, dan range
berasal dari `Response.file`, dan `Content-Disposition` tidak dikirim. Tipe yang
diperiksa browser selalu tepat: `text/javascript`, `text/css`,
`application/wasm`, `image/svg+xml`, `font/woff2`, `font/woff`, `font/ttf`,
`font/otf` (`mimeTypeOf`).

Direktori dipindai saat boot dan request dijawab dengan mencari path-nya di antara
file yang ditemukan, sehingga tidak ada bagian URL yang sampai ke file system:
`..`, `%2e%2e`, `%2f`, dan backslash hanya gagal ditemukan. Dot file (`.env`,
`.git`, `.vite`) dan symbolic link dilewati; link `public/storage` dari
`storage:link` mengarah ke upload, yang disajikan oleh disk
(`Storage.response`). Direktori yang tidak ada membatalkan boot. Beberapa
pemanggilan `withStatic` menambah direktori; `asset` memakai direktori pertama
yang memiliki file tersebut, dan `prefix: '/'` menyajikan dari root tanpa
menutupi route Anda.

Dengan `APP_ENV=local` (atau `rescan: true`) file baru ditemukan tanpa restart dan
file yang diubah mendapat versi baru. Di production, file yang ditemukan saat boot
adalah semua yang ada: deploy, lalu restart. Hashing membaca setiap file sekali
saat boot (per isolate); `dartisan static:hash` di langkah deploy menulis
`public/.static-manifest.json` berisi versi, ukuran, dan waktu modifikasi setiap
file, dan boot kemudian tidak membaca file yang ukuran dan waktunya masih sama.

Dengan Vite, `Assets.vite('resources/js/app.js')` (`Vite::asset()` di Laravel)
membaca `public/build/manifest.json` (atau `.vite/manifest.json` dari Vite biasa)
dan menghasilkan `/assets/build/assets/app-4ed993c7.js`; `asset()` melakukan hal
yang sama untuk source yang tercantum di manifest. File hasil build dinamai
menurut hash-nya, sehingga selalu disajikan sebagai immutable. Entry yang tidak
ada di manifest melempar exception, seperti di Laravel.

## Error

Exception dirender exception handler dengan body dari Laravel. Dengan
`APP_DEBUG=false`, tidak ada detail internal yang bocor:

| Situasi | Status | `message` |
| :-- | :-- | :-- |
| Validasi gagal | 422 | error pertama + `(and N more errors)`, ditambah `errors` |
| Belum login | 401 | `Unauthenticated.` |
| Ditolak gate / policy | 403 | `This action is unauthorized.` |
| Route tidak dikenal | 404 | `The route api/x could not be found.` |
| `findOrFail` / `firstOrFail` | 404 | `No query results for model [App\Models\Post] 1` |
| Verb salah | 405 | `The DELETE method is not supported for route ... Supported methods: GET, HEAD.` |
| Body terlalu besar | 413 | `The POST data is too large.` |
| Terkena rate limit | 429 | `Too Many Attempts.` |
| `abort(404)` tanpa pesan | 404 | string kosong, seperti Laravel |
| Selain itu | 500 | `Server Error` |

Ini adalah pesan Laravel 10 sampai 13; `COMPAT_LARAVEL_VERSION=8` atau `9`
menjawab dengan pesan Laravel yang lebih lama ([Koeksistensi dengan
Laravel](laravel-coexistence.md#versi-laravel-yang-lebih-lama)).
Seperti di Laravel, setiap error kecuali 401 dan 422 ditulis pretty-print
(empat spasi, `/` tidak di-escape: `Handler::prepareJsonResponse`), sedangkan
body 401 `Unauthenticated.` dan 422 compact, sehingga client yang membandingkan
byte melihat body yang sama.

Daftarkan renderer sendiri dengan `withExceptions((e) =>
e.render<MyError>((error, request) => Response.json({...}, status: 409)))`.
Renderer boleh `async`: renderer bisa menulis baris audit atau membaca
terjemahan sebelum menjawab.

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `$request->replace([...])` | `request.replace({...})` | `Request.replace` |  |
| `$request->float('price') / ->string('name')` | `await request.float('price') / .string('name')` | `Request.float` |  |
| `$request->bearerToken()` | `request.bearerToken()` | `Request.bearerToken` |  |
| `$request->expectsJson()` | `request.expectsJson` | `Request.expectsJson` |  |
| `$request->getRealMethod()` | `request.originalMethod` | `Request.originalMethod` |  |
| `back()` | `Response.back(request)` | `Response.back` |  |
| `<input name="_method"> / X-HTTP-Method-Override` | aktif secara default; middleware.methodOverride = false | `MethodOverrideMiddleware` |  |
| `->additional([...])` | `.additional({...})` | `JsonResource.additional` |  |
| `$this->when($cond, $value) / whenLoaded('posts')` | `when(cond, value) / whenLoaded('posts')` | `JsonResource.whenLoaded` |  |
| `public function with($request)` | `Map<String, Object?> withMeta(Request? request)` | `JsonResource.withMeta` | `with` adalah kata yang dicadangkan di Dart. |
