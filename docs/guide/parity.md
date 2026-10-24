<!-- GENERATED from parity.yaml by tool/docs/generate.dart. -->

# Laravel ⇄ Daravel parity

Laravel 12.x on the left, Daravel 1.x on the right. Every Daravel symbol below is checked against the source by `packages/daravel/test/parity_test.dart`, so this table cannot drift from the code. **async** marks calls you `await`.

## Routing

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Route::get($uri, $action)` | `router.get(path, handler)` |  |
| `Route::post / put / patch / delete` | `router.post / put / patch / delete` |  |
| `Route::match($methods, ...)` | `router.match(methods, path, handler)` |  |
| `Route::any(...)` | `router.any(path, handler)` |  |
| `Route::redirect($from, $to)` | `router.redirect(from, to)` |  |
| `Route::fallback(...)` | `router.fallback(handler)` |  |
| `Route::middleware(...)->prefix(...)->group(...)` | `router.group((r) {...}, prefix:, middleware:)` |  |
| `Route::apiResource('photos', PhotoController::class)` | `router.apiResource('photos', PhotoController())` |  |
| `Route::resource(...)` | `router.resource(name, controller)` |  |
| `->name('users.show')` | `.name('users.show')` |  |
| `->middleware(['auth'])` | `.middleware(const ['auth'])` |  |
| `->where('id', '[0-9]+') / ->whereNumber('id')` | `.where('id', r'\d+') / .whereNumber('id')` |  |
| `->whereUuid('id')` | `.whereUuid('id')` |  |
| `public function store(StorePostRequest $request)` | `.validates(const StorePostRequest())` | Validated before the handler; read with request.validated(). |
| `$request->validated()` | `request.validated()` |  |
| `(Scribe / Scramble response annotations)` | `.returns(schema, name:, shape:)` | Used by dartisan openapi:generate. |
| `route('users.show', ['id' => 1])` | `router.url('users.show', {'id': 1})` |  |

## Requests & responses

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `$request->validate($rules)` | `await request.validate(rules)` | **async** |
| `$request->all()` | `await request.all()` | **async** |
| `$request->input('a.b')` | `await request.input<T>('a.b')` | **async** |
| `$request->has('key')` | `await request.has('key')` | **async** |
| `$request->query('page')` | `request.query['page']` |  |
| `$request->header('x-id')` | `request.header('x-id')` |  |
| `$request->bearerToken()` | `request.bearerToken()` |  |
| `$request->ip()` | `request.ip` |  |
| `$request->url()` | `request.url` |  |
| `$request->route('id')` | `request.param<int>('id')` |  |
| `$request->expectsJson()` | `request.expectsJson` |  |
| `response()->json($data, $status)` | `Response.json(data, status: status)` |  |
| `response()->noContent()` | `Response.noContent()` |  |
| `redirect($to)` | `Response.redirect(to)` |  |
| `response()->streamDownload(...)` | `Response.stream(...)` |  |
| `abort(404, $message)` | `abort(404, message)` | Without a message the JSON message is empty, as in Laravel. |
| `class StoreUserRequest extends FormRequest` | `final class StoreUserRequest extends FormRequest` |  |

## Validation

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Validator::make($data, $rules)` | `Validator(data, rules)` |  |
| `$validator->fails()` | `await validator.fails()` | **async** |
| `$validator->validate()` | `await validator.validate()` | **async** |
| `ValidationException` | `ValidationException` |  |
| `Rule::in([...]) / Rule::unique('users')` | `Rules.inList([...]) / Rules.unique('users')` |  |

## Eloquent

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `class User extends Model` | `final class User extends Model` |  |
| `protected $table / $fillable / $hidden / $casts` | `ModelDefinition<User>(table:, fillable:, hidden:, casts:)` |  |
| `$model->getMorphClass()` | `User.definition.morphClass` |  |
| `User::query()` | `User.query()` |  |
| `User::where('a', $b)->first()` | `await User.query().where('a', b).first()` | **async** |
| `User::find($id) / findOrFail($id)` | `await User.query().find(id) / findOrFail(id)` | **async**; throws `ModelNotFoundException` |
| `->firstOrFail()` | `.firstOrFail()` | **async**; throws `ModelNotFoundException` |
| `User::create($attributes)` | `await User.query().create(attributes)` | **async** |
| `User::firstOrCreate / updateOrCreate` | `firstOrCreate / updateOrCreate` | **async** |
| `->with(['posts'])` | `.with_(['posts'])` | `with` is a reserved word in Dart. |
| `->withCount('posts')` | `.withCount('posts')` |  |
| `->whereHas('posts', fn)` | `.whereHas('posts', (q) {...})` |  |
| `->paginate(15)` | `await query.paginate(perPage: 15)` | **async**; Page and path come from the current request, like Laravel. |
| `->simplePaginate() / cursorPaginate()` | `.simplePaginate() / .cursorPaginate()` | **async** |
| `->latest() / oldest()` | `.latest() / .oldest()` |  |
| `->withTrashed() / onlyTrashed()` | `.withTrashed() / .onlyTrashed()` |  |
| `$model->save() / update() / delete()` | `await model.save() / update() / delete()` | **async** |
| `$model->restore() / forceDelete()` | `await model.restore() / forceDelete()` | **async** |
| `$model->isDirty() / wasChanged()` | `model.isDirty() / wasChanged()` |  |
| `$model->refresh() / fresh()` | `await model.refresh() / fresh()` | **async** |
| `$model->load('posts')` | `await model.load('posts')` | **async** |
| `$model->toArray() / toJson()` | `model.toJson()` |  |
| `ModelNotFoundException` | `ModelNotFoundException` |  |

## Database

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `DB::table('users')` | `DB.table('users')` |  |
| `DB::select($sql, $bindings)` | `await DB.select(sql, bindings)` | **async** |
| `DB::statement($sql)` | `await DB.statement(sql)` | **async** |
| `DB::transaction(fn)` | `await DB.transaction(() async {...})` | **async** |
| `DB::raw($sql)` | `DB.raw(sql)` |  |
| `DB::listen(fn (QueryExecuted $q) => ...)` | `DB.listen((QueryExecuted q) {...})` |  |
| `->insertGetId($values)` | `await DB.table(t).insertGetId(values)` | **async** |
| `->upsert($values, $uniqueBy)` | `.upsert(values, uniqueBy)` | **async** |
| `->chunkById(100, fn)` | `.chunkById(100, (rows) async {...})` | **async** |
| `->toSql() / toRawSql()` | `.toSql() / .toRawSql()` |  |

## Schema & migrations

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Schema::create('users', fn (Blueprint $table) => ...)` | `schema.create('users', (table) {...})` | **async** |
| `Schema::table / dropIfExists / hasTable / hasColumn` | `schema.table / dropIfExists / hasTable / hasColumn` | **async** |
| `$table->id() / string() / foreignId()->constrained()` | `table.id() / string() / foreignId().constrained()` |  |
| `$table->timestamps() / softDeletes() / rememberToken()` | `table.timestamps() / softDeletes() / rememberToken()` |  |
| `return new class extends Migration { up / down }` | `final class CreateX extends Migration { up / down }` |  |
| `class DatabaseSeeder extends Seeder` | `final class DatabaseSeeder extends Seeder` |  |
| `User::factory()->count(3)->create()` | `UserFactory().count(3).create()` |  |

## Auth & security

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `auth()->user() / Auth::user()` | `await Auth.user()` | **async** |
| `Auth::id() / check() / guest()` | `await Auth.id() / check() / guest()` | **async** |
| `Auth::guard('api')` | `Auth.guard('api')` |  |
| `$user->createToken($name, $abilities)` | `await Auth.issueToken(user, name, abilities: [...])` | **async** |
| `$user->currentAccessToken()->delete()` | `await Auth.tokenGuard().revokeCurrent()` | **async** |
| `$user->tokenCan('posts:read')` | `await Auth.tokenGuard().tokenCan('posts:read')` | **async** |
| `Hash::make / check / needsRehash` | `await Hash.make / check, Hash.needsRehash` |  |
| `Crypt::encryptString / decryptString` | `await Crypt.encryptString / decryptString` | **async**; Byte-compatible with APP_CIPHER=AES-256-CBC or AES-256-GCM. |
| `Crypt::encrypt / decrypt` | `await Crypt.encrypt / decrypt` | **async**; Values are JSON-encoded, not PHP-serialized: not cross-runtime. |
| `Gate::define / allows / denies / authorize` | `Gate.define / allows / denies / authorize` | **async** |
| `class PostPolicy` | `final class PostPolicy extends Policy<Post>` |  |
| `RateLimiter::for('login', fn)` | `limiter.define('login', (request) => Limit.perMinute(5))` |  |
| `Limit::perMinute(60)->by($key)` | `Limit.perMinute(60).by(key)` |  |

## Cache, queue, events, scheduling

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Cache::get / put / forget / has` | `await Cache.get / put / forget / has` | **async** |
| `Cache::remember($key, $ttl, fn)` | `await Cache.remember(key, ttl, () async {...})` | **async** |
| `Cache::flexible($key, [$fresh, $stale], fn)` | `await Cache.flexible(...)` | **async** |
| `Cache::lock('name', 10)->get(fn)` | `await Cache.lock('name', ...)` |  |
| `SendEmail::dispatch($user)` | `await Queue.dispatch(SendEmail(user))` | **async** |
| `Queue::later($delay, $job)` | `await Queue.later(delay, job)` | **async** |
| `public function tags() (Horizon)` | `List<String> get tags` |  |
| `php artisan queue:pause database:default / queue:continue` | `dartisan queue:pause database:default / queue:continue` |  |
| `class SendEmail implements ShouldQueue` | `final class SendEmail extends Job` |  |
| `event(new OrderShipped($order))` | `await Event.dispatch(OrderShipped(order))` | **async** |
| `Event::listen(OrderShipped::class, fn)` | `Event.listen<OrderShipped>((e) async {...})` |  |
| `Event::fake() / Queue::fake()` | `Event.fake() / Queue.fake()` |  |
| `Schedule::command('reports:send')->daily()` | `schedule.command('reports:send').daily()` |  |
| `->everyFiveMinutes() / dailyAt('13:00')` | `.everyFiveMinutes() / .dailyAt('13:00')` |  |
| `->withoutOverlapping() / onOneServer()` | `.withoutOverlapping() / .onOneServer()` |  |

## Resources, storage, logging, config

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `class UserResource extends JsonResource { toArray }` | `final class UserResource extends JsonResource<User> { toArray }` |  |
| `UserResource::collection($users)` | `JsonResource.collection(users, UserResource.new)` |  |
| `->additional([...])` | `.additional({...})` |  |
| `$this->when($cond, $value) / whenLoaded('posts')` | `when(cond, value) / whenLoaded('posts')` |  |
| `public function with($request)` | `Map<String, Object?> withMeta(Request? request)` | `with` is a reserved word in Dart. |
| `Storage::disk('public')->put($path, $contents)` | `await Storage.disk('public').put(path, contents)` |  |
| `Storage::url($path)` | `Storage.url(path)` |  |
| `Log::info($message, $context)` | `Log.info(message, context)` |  |
| `Log::withContext([...])` | `Log.withContext({...})` |  |
| `config('app.name')` | `Config.get<String>('app.name')` |  |
| `app(Service::class)` | `App.make<Service>()` |  |
| `now()` | `Clock.now()` | Frozen by freezeTime()/travel() in tests. |

## Strings, helpers, collections

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Str::slug / snake / camel / studly / kebab / title / headline` | `Str.slug / snake / camel / studly / kebab / title / headline` |  |
| `Str::limit / words / mask / squish` | `Str.limit / words / mask / squish` |  |
| `Str::after / before / between / start / finish` | `Str.after / before / between / start / finish` |  |
| `Str::contains / startsWith / endsWith` | `Str.contains / startsWith / endsWith` |  |
| `Str::plural / singular / pluralStudly` | `Str.plural / singular / pluralStudly` | English rules with common irregulars. |
| `Str::random / uuid / ulid / isUuid / isJson` | `Str.random / uuid / ulid / isUuid / isJson` |  |
| `abort_if / abort_unless` | `abortIf / abortUnless` |  |
| `retry(, fn, )` | `await retry(times, (attempt) async {...}, delay:)` | **async** |
| `rescue(fn, )` | `await rescue(() async {...}, fallback:)` | **async** |
| `once(fn)` | `once(key, () => ...)` | Keyed explicitly; memoized per request/job/command scope. |
| `blank / filled / tap / value / data_get` | `blank / filled / tap / value / dataGet` |  |
| `now() / today()` | `now() / today()` |  |
| `collect($rows)->pluck('email')` | `rows.pluck('email')` | Extensions on Iterable: no conversion to a Collection. |
| `->keyBy / groupBy / chunk / unique` | `.keyBy / groupBy / chunk / unique` |  |
| `->sum / avg / sortBy / sortByDesc / partition` | `.sumBy / avgBy / sortBy / sortByDesc / partition` |  |

## Testing

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `$this->getJson('/api/users')` | `await client.get('/api/users')` | **async** |
| `$this->postJson($uri, $data)` | `await client.post(uri, json: data)` | **async** |
| `$this->actingAs($user)` | `client.actingAs(user)` |  |
| `->assertOk() / assertCreated() / assertUnprocessable()` | `.assertOk() / .assertCreated() / .assertUnprocessable()` |  |
| `->assertJsonPath('data.id', 1)` | `.assertJsonPath('data.id', 1)` |  |
| `use RefreshDatabase;` | `refreshDatabase(() => app)` |  |
| `$this->freezeTime() / travel(5)->minutes()` | `freezeTime() / travel(Duration(minutes: 5))` |  |

## Middleware aliases

| Laravel | Daravel |
| :-- | :-- |
| `auth` | `auth` |
| `auth:sanctum` | `auth:token` |
| `throttle` | `throttle` |
| `can` | `can` |
| `signed` | `signed` |

## Not available yet

| Laravel | Plan |
| :-- | :-- |
| MySQL / MariaDB runtime driver | Tier 2 (grammars exist; ADR-019) |
| Polymorphic relations (morphTo, morphMany, ...) | Tier 2 |
| Blade templates | Tier 3 (typed HTML builder) |
| Sessions, CSRF, SPA cookie auth | Tier 2 |
| Multipart uploads / UploadedFile | Tier 2 |
| Mail, notifications, broadcasting | Tier 2/3 |
| Redis cache/queue/lock, S3 storage | Tier 2 |
| PHP serialize() for Crypt::encrypt payloads | Tier 2 (Laravel-compatible Crypt mode) |
| optional() helper | Not planned: Dart has ?. and ?? |
| app() / route() / url() global helpers | Use App.make<T>(), router.url(...); a global app() would be shadowed by the idiomatic app variable |
| dd() / dump() | Not planned: use print or Log in development |
