import 'site.dart';

/// A Laravel ⇄ Daravel pair shown on the landing page.
final class _Pair {
  const _Pair(this.id, this.tab, this.php, this.dart, this.note);

  final String id;
  final Map<String, String> tab;
  final String php;
  final String dart;
  final Map<String, String> note;
}

const List<_Pair> _pairs = [
  _Pair(
    'routes',
    {'en': 'Routes and validation', 'id': 'Route dan validasi'},
    r'''
Route::post('/posts', [PostController::class, 'store'])
    ->middleware('auth:sanctum');

public function store(StorePostRequest $request)
{
    $post = Post::create($request->validated());

    return new PostResource($post);
}''',
    r'''
router.post('/posts', posts.store)
    .middleware(const ['auth'])
    .validates(const StorePostRequest())
    .returns(PostResource.schema, name: 'Post');

Future<Object?> store(Request request) async {
  final post = await Post.create(request.validated().toMap());

  return PostResource(post);
}''',
    {
      'en':
          'The form request runs before the handler, answers 403 or 422 in '
          'Laravel’s format, and the same declaration documents the route in '
          'OpenAPI.',
      'id':
          'Form request dijalankan sebelum handler, menjawab 403 atau 422 '
          'dalam format Laravel, dan deklarasi yang sama mendokumentasikan '
          'route di OpenAPI.',
    },
  ),
  _Pair(
    'orm',
    {'en': 'Models and relations', 'id': 'Model dan relasi'},
    r'''
$users = User::with('posts')
    ->withCount('posts')
    ->where('active', true)
    ->paginate();

$user->roles()->sync([2, 3]);''',
    r'''
final users = await User.query()
    .with_(['posts'])
    .withCount('posts')
    .where('active', true)
    .paginate();

await user.sync('roles', [2, 3]);''',
    {
      'en':
          'The same query builder, eager loading and pagination JSON. `with` '
          'is a reserved word in Dart, hence `with_`.',
      'id':
          'Query builder, eager loading, dan JSON paginasi yang sama. `with` '
          'adalah kata kunci di Dart, jadi namanya `with_`.',
    },
  ),
  _Pair(
    'transactions',
    {'en': 'Transactions and queues', 'id': 'Transaksi dan queue'},
    r'''
DB::transaction(function () use ($data) {
    $order = Order::create($data);

    // Dispatched after the commit.
    SendReceipt::dispatch($order);
});''',
    r'''
await DB.transaction(() async {
  final order = await Order.create(data);

  // Dispatched after the commit.
  await Queue.dispatch(SendReceipt(order.id));
});''',
    {
      'en':
          'Transactions follow the request’s zone: nested calls become '
          'savepoints, and jobs wait for the outer commit or are dropped on '
          'rollback.',
      'id':
          'Transaksi mengikuti zone request: panggilan bertingkat menjadi '
          'savepoint, dan job menunggu commit terluar atau dibuang saat '
          'rollback.',
    },
  ),
  _Pair(
    'cache',
    {'en': 'Cache, locks and limits', 'id': 'Cache, lock, dan limit'},
    r'''
$stats = Cache::remember('stats', 60, fn () => Stats::compute());

Cache::lock('report')->block(5, fn () => Report::build());

Route::get('/search', SearchController::class)
    ->middleware('throttle:60,1');''',
    r'''
final stats = await Cache.remember(
    'stats', const Duration(minutes: 1), () => Stats.compute());

await Cache.lock('report')
    .block(const Duration(seconds: 5), () => Report.build());

router.get('/search', search.index)
    .middleware(const ['throttle:60,1']);''',
    {
      'en':
          'With several worker isolates, locks, the process cache and rate '
          'limits are kept by a coordinator isolate: 60 per minute means 60 '
          'for the whole server, without Redis.',
      'id':
          'Dengan beberapa worker isolate, lock, cache proses, dan rate limit '
          'dijaga oleh isolate coordinator: 60 per menit berarti 60 untuk '
          'seluruh server, tanpa Redis.',
    },
  ),
  _Pair(
    'testing',
    {'en': 'Testing', 'id': 'Pengujian'},
    r'''
Queue::fake();

$this->actingAs($user)
    ->postJson('/api/posts', ['title' => 'Hello'])
    ->assertCreated()
    ->assertJsonPath('data.title', 'Hello');

Queue::assertPushed(PublishPost::class);''',
    r'''
final queue = Queue.fake();

(await client.actingAs(user)
        .post('/api/posts', json: {'title': 'Hello'}))
    .assertCreated()
    .assertJsonPath('data.title', 'Hello');

queue.assertPushed<PublishPost>();''',
    {
      'en':
          'Feature tests run the real kernel in memory, roll the database back '
          'after each test, and fake queues, events, storage, HTTP and time.',
      'id':
          'Feature test menjalankan kernel sungguhan di memori, me-rollback '
          'database setelah setiap test, dan memalsukan queue, event, storage, '
          'HTTP, dan waktu.',
    },
  ),
];

const Map<String, Map<String, String>> _text = {
  'en': {
    'title': 'Daravel: the Laravel developer experience, compiled',
    'h1':
        'The Laravel developer experience, compiled to a single native binary.',
    'lede':
        'Routes, form requests, an Eloquent-style ORM, Sanctum tokens, queues '
        'and a scheduler, in Dart. The server is one ahead-of-time compiled '
        'executable that uses every core, and it runs next to your Laravel '
        'application on the same database.',
    'start': 'Get started',
    'migrate': 'Migrating from Laravel',
    'copy': 'Copy',
    'whyTitle': 'What you get from Dart without losing Laravel',
    'whyLede':
        'Every point links to the chapter that explains it, and each is '
        'checked by the test suite.',
    'measuredTitle': 'Measured, not claimed',
    'measuredLede':
        'The benchmark harness builds the servers ahead of time and runs them '
        'next to a plain dart:io server on the same machine.',
    'startup': 'from start to the first answered request',
    'memory': 'idle memory with one worker, 12 MB with four',
    'throughput':
        'of plain dart:io throughput for GET /ping with four isolates',
    'source':
        'GitHub Actions Linux runner, 4 CPUs, benchmark run 40092549095. '
        'Method and every scenario:',
    'packagesTitle': 'Packages',
    'packagesLede': 'Published together on pub.dev under one version.',
    'planned': 'Planned',
    'footerLicense': 'MIT license',
    'footerTrademarks':
        'Laravel is a trademark of Laravel Holdings Inc.; Dart and Flutter are '
        'trademarks of Google LLC. Daravel is independent of both.',
  },
  'id': {
    'title': 'Daravel: pengalaman developer Laravel, dikompilasi',
    'h1':
        'Pengalaman developer Laravel, dikompilasi menjadi satu binary native.',
    'lede':
        'Route, form request, ORM gaya Eloquent, token Sanctum, queue, dan '
        'scheduler, dalam Dart. Server-nya satu executable hasil kompilasi '
        'AOT yang memakai semua core, dan berjalan berdampingan dengan '
        'aplikasi Laravel Anda di database yang sama.',
    'start': 'Mulai',
    'migrate': 'Migrasi dari Laravel',
    'copy': 'Salin',
    'whyTitle': 'Yang Anda dapat dari Dart tanpa kehilangan Laravel',
    'whyLede':
        'Setiap poin menaut ke bab yang menjelaskannya, dan masing-masing '
        'diperiksa oleh test suite.',
    'measuredTitle': 'Diukur, bukan diklaim',
    'measuredLede':
        'Harness benchmark membangun server secara AOT dan menjalankannya '
        'berdampingan dengan server dart:io polos di mesin yang sama.',
    'startup': 'dari start sampai request pertama terjawab',
    'memory': 'memori idle dengan satu worker, 12 MB dengan empat',
    'throughput':
        'dari throughput dart:io polos untuk GET /ping dengan empat isolate',
    'source':
        'Runner Linux GitHub Actions, 4 CPU, run benchmark 40092549095. '
        'Metode dan semua skenario:',
    'packagesTitle': 'Paket',
    'packagesLede': 'Diterbitkan bersama di pub.dev dengan satu versi.',
    'planned': 'Direncanakan',
    'footerLicense': 'Lisensi MIT',
    'footerTrademarks':
        'Laravel adalah merek dagang Laravel Holdings Inc.; Dart dan Flutter '
        'adalah merek dagang Google LLC. Daravel tidak berafiliasi dengan '
        'keduanya.',
  },
};

/// (title, text, page) per language.
const Map<String, List<(String, String, String)>> _reasons = {
  'en': [
    (
      'One native bundle',
      'The application compiles ahead of time into machine code, with SQLite bundled. The server needs no SDK, runtime or source code.',
      'deployment.html',
    ),
    (
      'No reflection, no build step',
      'Generators write plain Dart into explicit registries, so the compiler sees exactly the code you read.',
      'architecture.html',
    ),
    (
      'Every core on one port',
      'A supervisor runs worker isolates, respawns crashes and drains on SIGTERM; a coordinator keeps locks and rate limits correct across them.',
      'architecture.html',
    ),
    (
      'Request state stays in its request',
      'Each request, job and command runs in its own zone, so facades and transactions never leak into another request.',
      'architecture.html',
    ),
    (
      'Next to Laravel, on the same database',
      'Tokens, bcrypt hashes, Crypt payloads, error JSON and shared tables are Laravel 12’s. Move one endpoint at a time.',
      'migrating-from-laravel.html',
    ),
    (
      'Routes that document themselves',
      'Declared validation and responses answer 403 and 422 before your handler and generate OpenAPI 3.1.',
      'routing.html',
    ),
    (
      'Guard rails included',
      'Hashing off the event loop, lints against SQL interpolation, and security and Laravel conformance suites in CI.',
      'security.html',
    ),
  ],
  'id': [
    (
      'Satu bundle native',
      'Aplikasi dikompilasi AOT menjadi kode mesin, dengan SQLite terbawa. Server tidak butuh SDK, runtime, atau source code.',
      'deployment.html',
    ),
    (
      'Tanpa reflection, tanpa langkah build',
      'Generator menulis Dart biasa ke registry yang eksplisit, jadi compiler melihat persis kode yang Anda baca.',
      'architecture.html',
    ),
    (
      'Semua core di satu port',
      'Supervisor menjalankan worker isolate, me-respawn yang crash, dan menguras request saat SIGTERM; coordinator menjaga lock dan rate limit tetap benar.',
      'architecture.html',
    ),
    (
      'State request tetap di request-nya',
      'Setiap request, job, dan command berjalan di zone sendiri, jadi facade dan transaksi tidak bocor ke request lain.',
      'architecture.html',
    ),
    (
      'Berdampingan dengan Laravel, di database yang sama',
      'Token, hash bcrypt, payload Crypt, JSON error, dan tabel bersama mengikuti Laravel 12. Pindahkan endpoint satu per satu.',
      'migrating-from-laravel.html',
    ),
    (
      'Route yang mendokumentasikan dirinya',
      'Validasi dan respons yang dideklarasikan menjawab 403 dan 422 sebelum handler, dan menghasilkan OpenAPI 3.1.',
      'routing.html',
    ),
    (
      'Pengaman bawaan',
      'Hashing di luar event loop, lint untuk interpolasi SQL, serta suite keamanan dan konformansi Laravel di CI.',
      'security.html',
    ),
  ],
};

const List<(String, Map<String, String>, bool)> _packages = [
  ('daravel', {'en': 'The framework.', 'id': 'Framework-nya.'}, false),
  (
    'dartisan_cli',
    {
      'en': 'Projects, generators, hot reload, migrations, native builds.',
      'id': 'Proyek, generator, hot reload, migrasi, build native.',
    },
    false,
  ),
  (
    'daravel_test',
    {
      'en':
          'TestClient, database helpers, fakes, Laravel conformance matchers.',
      'id': 'TestClient, helper database, fake, matcher konformansi Laravel.',
    },
    false,
  ),
  (
    'daravel_lints',
    {
      'en': 'Lint rules for Daravel applications.',
      'id': 'Aturan lint untuk aplikasi Daravel.',
    },
    false,
  ),
  (
    'daravel_horizon, daravel_socialite, daravel_reverb',
    {
      'en': 'Queue dashboard, OAuth sign-in, WebSockets.',
      'id': 'Dashboard queue, login OAuth, WebSocket.',
    },
    true,
  ),
  (
    'daragic',
    {
      'en': 'Laravel ⇄ Daravel project generator.',
      'id': 'Generator proyek Laravel ⇄ Daravel.',
    },
    true,
  ),
];

/// The landing page in [lang]; [docs] leads to the documentation and
/// [prefix] to the site root.
String landingPage({
  required String lang,
  required String docs,
  required String prefix,
  required String releaseVersion,
  required String Function(String page) link,
}) {
  final t = _text[lang]!;
  final tabs = StringBuffer();
  final panels = StringBuffer();
  for (final (index, pair) in _pairs.indexed) {
    final selected = index == 0;
    tabs.write(
      '<button role="tab" id="tab-${pair.id}" aria-controls="pair-${pair.id}" '
      'aria-selected="$selected" tabindex="${selected ? 0 : -1}" type="button">'
      '${escapeHtml(pair.tab[lang]!)}</button>',
    );
    panels.write(
      '<div class="pair" role="tabpanel" id="pair-${pair.id}" '
      'aria-labelledby="tab-${pair.id}"${selected ? '' : ' hidden'}>'
      '<div class="side"><h3>Laravel</h3><pre><code class="language-php">'
      '${escapeHtml(pair.php)}</code></pre></div>'
      '<div class="seam" aria-hidden="true"></div>'
      '<div class="side"><h3>Daravel</h3><pre><code class="language-dart">'
      '${escapeHtml(pair.dart)}</code></pre></div>'
      '<p class="note">${escapeHtml(pair.note[lang]!).replaceAllMapped(RegExp('`([^`]+)`'), (m) => '<code>${m[1]}</code>')}</p>'
      '</div>',
    );
  }
  final reasons = [
    for (final (title, text, page) in _reasons[lang]!)
      '<div><dt><a href="${link(page)}">${escapeHtml(title)}</a></dt>'
          '<dd>${escapeHtml(text)}</dd></div>',
  ].join();
  final packages = [
    for (final (name, text, planned) in _packages)
      '<tr${planned ? ' class="planned"' : ''}><td>'
          '${planned ? escapeHtml(name) : '<a href="https://pub.dev/packages/$name">$name</a>'}'
          '</td><td>${escapeHtml(text[lang]!)}'
          '${planned ? ' (${t['planned']})' : ''}</td></tr>',
  ].join();
  const install = 'dart pub global activate dartisan_cli && dartisan new blog';
  return '''
${pageHead(title: t['title']!, prefix: prefix, lang: lang)}
<body>
${topBar(prefix: prefix, docs: docs, lang: lang, releaseVersion: releaseVersion, enHref: '${prefix}index.html', idHref: '${prefix}id/index.html')}
<main id="content">
<section class="hero">
<h1>${escapeHtml(t['h1']!)}</h1>
<p class="lede">${escapeHtml(t['lede']!)}</p>
<div class="actions">
<a class="button primary" href="${docs}getting-started.html">${t['start']}</a>
<a class="button secondary" href="${docs}migrating-from-laravel.html">${t['migrate']}</a>
<span class="install"><code>$install</code><button type="button" data-copy="$install">${t['copy']}</button></span>
</div>
</section>
<section class="compare" aria-label="Laravel and Daravel">
<div class="tabs" role="tablist">$tabs</div>
$panels
</section>
<section class="section">
<h2>${escapeHtml(t['whyTitle']!)}</h2>
<p>${escapeHtml(t['whyLede']!)}</p>
<dl class="reasons">$reasons</dl>
</section>
<section class="section">
<h2>${escapeHtml(t['measuredTitle']!)}</h2>
<p>${escapeHtml(t['measuredLede']!)}</p>
<div class="measures">
<div class="measure"><strong>14 ms</strong><span>${t['startup']}</span></div>
<div class="measure"><strong>11 MB</strong><span>${t['memory']}</span></div>
<div class="measure"><strong>78%</strong><span>${t['throughput']}</span><div class="bar" role="img" aria-label="78%"><i style="width:78%"></i></div></div>
</div>
<p class="source">${t['source']} <a href="${link('performance.html')}">${docs.contains('id/') ? 'Performa' : 'Performance'}</a>.</p>
</section>
<section class="section">
<h2>${t['packagesTitle']}</h2>
<p>${t['packagesLede']}</p>
<table class="packages">$packages</table>
</section>
</main>
<footer class="footer">
<span>Daravel $releaseVersion</span>
<a href="https://github.com/daravel-dev/daravel">GitHub</a>
<a href="https://pub.dev/packages/daravel">pub.dev</a>
<a href="https://github.com/daravel-dev/daravel/blob/main/LICENSE">${t['footerLicense']}</a>
<span>${escapeHtml(t['footerTrademarks']!)}</span>
</footer>
${searchDialog(index: '${docs.replaceAll('id/', '')}search-index.json', base: docs.replaceAll('id/', ''), lang: lang)}
</body>
</html>
''';
}
