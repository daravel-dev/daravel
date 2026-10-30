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
| `$request->merge([...])` | `await request.merge({...})` | **async** |
| `$request->replace([...])` | `request.replace({...})` |  |
| `$request->has('key')` | `await request.has('key')` | **async** |
| `$request->integer('page', 1)` | `await request.integer('page', 1)` | **async** |
| `$request->boolean('remember')` | `await request.boolean('remember')` | **async** |
| `$request->float('price') / ->string('name')` | `await request.float('price') / .string('name')` | **async** |
| `$request->query('page')` | `request.query['page']` |  |
| `$request->query() (ids[]=1&ids[]=2)` | `request.queryInput` | Brackets build lists and maps, as PHP parse_str. |
| `$request->query->getInt('page', 1)` | `request.queryInt('page', 1) / queryDouble / queryBool / queryString` | Synchronous: the query string is in memory. |
| `$request->header('x-id')` | `request.header('x-id')` |  |
| `$request->file('avatar') / hasFile('avatar')` | `await request.file('avatar') / hasFile('avatar')` | **async**; Multipart bodies stream to temporary files. |
| `$file->store('avatars', 'public') / storeAs(...)` | `await file.store('avatars', disk: 'public')` | **async** |
| `UploadedFile::fake()->image('a.png')` | `UploadedFile.fake.image('a.png')` |  |
| `$request->bearerToken()` | `request.bearerToken()` |  |
| `$request->ip()` | `request.ip` |  |
| `$request->url()` | `request.url` |  |
| `$request->route('id')` | `request.param<int>('id')` |  |
| `$request->expectsJson()` | `request.expectsJson` |  |
| `$request->cookie('theme') / ->cookies->all()` | `request.cookie('theme') / request.cookies` | Decoded like $_COOKIE; EncryptCookies is not applied. |
| `response(...)->withCookie(cookie('theme', 'dark', 60))` | `response.withCookie('theme', 'dark', maxAge: Duration(minutes: 60))` | Same Set-Cookie text as Symfony's Cookie. |
| `response(...)->withoutCookie('theme') / Cookie::forget('theme')` | `response.withoutCookie('theme')` |  |
| `response()->json($data, $status)` | `Response.json(data, status: status)` | phpCompatible: true writes json_encode's bytes (\/, \u escapes, [] for an empty map). |
| `Blade views ({{ $name }}, {!! $html !!})` | `div([user.name]) / raw(html) from package:daravel/html.dart` | Typed builder, escaped by default; a separate import. |
| `response()->noContent()` | `Response.noContent()` |  |
| `redirect($to)` | `Response.redirect(to)` |  |
| `response()->streamDownload(...)` | `Response.stream(...)` |  |
| `response()->streamJson(['data' => $generator])` | `Response.streamJson(stream, wrap: 'data')` | One JSON array written as the items arrive, the bytes of `Response.json` for the collected list; `phpCompatible: true` for `json_encode()` bytes. |
| `response()->eventStream(fn () => ...)` | `Response.sse(stream)` | Same frames and `</stream>` end event; adds heartbeats and ends on shutdown. |
| `new StreamedEvent(event: 'tick', data: $data)` | `SseEvent(data, event: 'tick')` |  |
| `A custom WebSocket endpoint (outside Reverb channels)` | `router.ws('/ws/x', (socket, request) {...})` | A plain WebSocket after the route's middleware; Reverb and Pusher channels are under Broadcasting. |
| `abort(404, $message)` | `abort(404, message)` | Without a message the JSON message is empty, as in Laravel. |
| `class StoreUserRequest extends FormRequest` | `final class StoreUserRequest extends FormRequest` |  |

## Mail and notifications

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Mail::to($user)->send(new OrderShipped($order))` | `await Mail.to(user).send(OrderShipped(order))` | **async** |
| `class OrderShipped extends Mailable (envelope, content, attachments)` | `final class OrderShipped extends Mailable` |  |
| `Mail::to($user)->queue(new OrderShipped) / later($delay, ...)` | `await Mail.to(user).queue(OrderShipped()) / later(delay, ...)` | **async**; Rendered when queued; the job carries the message. |
| `class OrderShipped extends Mailable implements ShouldQueue` | `final class OrderShipped extends Mailable with ShouldQueue` | Also for notifications. |
| `Mail::fake(); Mail::assertSent(OrderShipped::class)` | `final mail = Mail.fake(); mail.assertSent<OrderShipped>()` |  |
| `MAIL_MAILER=smtp / log / array` | `MAIL_MAILER=smtp / log / array` | Same keys as config/mail.php; MAIL_ENCRYPTION from Laravel 10 is read too. |
| `$user->notify(new InvoicePaid($invoice))` | `await user.notify(InvoicePaid(invoice))` | **async** |
| `Notification::send($users, new InvoicePaid)` | `await Notifications.send(users, InvoicePaid())` | **async**; Notifications, plural: Notification is the base class. |
| `Notification::route('mail', $address)->notify(...)` | `Notifications.route('mail', address).notify(...)` |  |
| `(new MailMessage)->line()->action()` | `NotificationMail().line().action()` |  |
| `$user->unreadNotifications / markAsRead()` | `user.notifications(unreadOnly: true) / Notifications.markAsRead(user)` | **async** |
| `php artisan make:notifications-table` | `CreateNotificationsTable()` | Laravel's table; created only when missing. |
| `new Content(markdown: 'mail.orders.shipped')` | `MailContent(markdown: '...')` | Markdown in Dart, not a Blade view; Laravel's default theme, inlined. |
| `<x-mail::button :url="$url" color="success">` | `mailButton(label, url, color: 'success')` | The <x-mail::button> and <x-mail::panel> tags work in the markdown too. |
| `php artisan vendor:publish --tag=laravel-mail (theme CSS)` | `.withMailTheme((theme) => theme.copyWith(primary: '#4f46e5'))` |  |
| `via() => ['broadcast'] (BroadcastNotificationCreated)` | `via() => ['broadcast']` | Same event, data and channel (private-App.Models.User.1): Echo's .notification() receives it. |

## Broadcasting

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `php artisan reverb:start (Laravel Reverb)` | `.withBroadcasting(...) with REVERB_APP_ID / _KEY / _SECRET` | The Pusher protocol on the HTTP port; Laravel Echo and pusher-js connect unchanged. |
| `Broadcast::channel('orders.{id}', fn ($user, $id) => ...)` | `channels.channel('orders.{id}', (user, p) => ...)` | routes/channels.php: false refuses, true admits, a map is the presence member. |
| `class OrderShipped implements ShouldBroadcast` | `final class OrderShipped with ShouldBroadcast` | broadcastWith says what to send (no reflection); broadcast when dispatched. |
| `broadcast(new OrderShipped($order))->toOthers()` | `await Broadcast.event(OrderShipped(order).toOthers())` | **async** |
| `BROADCAST_CONNECTION=reverb / pusher / log / null` | `BROADCAST_CONNECTION=daravel / reverb / pusher / log / null` | **async**; daravel: this server; reverb and pusher: their HTTP API, signed as pusher-php-server. |
| `Pusher HTTP API (POST /apps/{id}/events)` | `the same endpoints, signatures checked` | **async**; Laravel broadcasts through Daravel with BROADCAST_CONNECTION=reverb. |
| `Echo.channel('cache-prices') (Pusher cache channels)` | `Broadcast.send(..., ['cache-prices'], ...)` | The last event is kept 30 minutes for new subscribers. |
| `Echo.encryptedPrivate('orders.7') with encryption_master_key_base64` | `REVERB_ENCRYPTION_MASTER_KEY_BASE64` | private-encrypted- channels, sealed with libsodium's secretbox. |
| `REVERB_SCALING_ENABLED=true (Reverb with Redis)` | `REVERB_SCALING_ENABLED=true (the database)` | Frames, presence members (here included) and cache channels span every server; PostgreSQL NOTIFY, MySQL polling. |
| `(Reverb's internal pub/sub)` | `await Broadcast.publish('orders.7', data)` | **async**; Daravel's own channels between isolates, for custom WebSocket and SSE routes. |

## Redis (daravel_redis)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Redis::command('HSET', [...])` | `await Redis.command(['HSET', ...])` | **async** |
| `Redis::throttle('key')->allow(10)->every(60)->then(fn, fn)` | `await Redis.throttle('key').allow(10).every(const Duration(seconds: 60)).then(() {...}, (e) {...})` | **async**; Laravel's DurationLimiter script and key: both count against one limit. |
| `Redis::funnel('key')->limit(3)->then(fn, fn)` | `await Redis.funnel('key').limit(3).then(() {...}, (e) {...})` | **async**; Laravel's ConcurrencyLimiter script and slot keys. |
| `Redis::publish($channel, $message)` | `await Redis.publish(channel, message)` | **async** |
| `Redis::subscribe([...], fn ($message) => ...)` | `Redis.subscribe([...]).messages.listen(...)` | Subscribes again after the connection drops. |
| `CACHE_STORE=redis` | `CACHE_STORE=redis with .withRedis()` | Numbers stored raw; cache:clear deletes the cache's keys, not the database (no FLUSHDB). |
| `Cache::lock('report')->get(...) on Redis` | `Cache.lock('report') on CACHE_STORE=redis` | **async**; Laravel's RedisLock: the same keys and release script. |
| `QUEUE_CONNECTION=redis` | `QUEUE_CONNECTION=redis` | BLPOP wakes idle workers; keys under daravel:, apart from Laravel's queues:. |
| `REVERB_SCALING_ENABLED=true (Redis)` | `REVERB_SCALING_DRIVER=redis` | Pub/Sub between servers; presence members shared across them. |

## Sessions (daravel_session)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Route::middleware('web')` | `.group(routes, middleware: ['web'])` | withSession() registers encrypt_cookies, session and csrf, and the web group that runs them in Laravel's order. |
| `$request->session() / session()` | `request.session / Session.current` |  |
| `session()->get('key', $default) / put / has / forget` | `session.get<T>('key', fallback) / put / has / forget` | Dot keys nest as in Laravel; stored as PHP serialize() with Laravel's _token, _flash and _previous keys. |
| `session()->flash('status', 'Saved') / reflash / keep / now` | `session.flash('status', 'Saved') / reflash / keep / now` |  |
| `session()->regenerate() / invalidate()` | `await session.regenerate() / invalidate()` | **async** |
| `csrf_token()` | `session.token` |  |
| `EncryptCookies middleware` | `EncryptCookiesMiddleware` | Crypt payload with CookieValuePrefix (hmac_sha1(name.'v2', key).'|'), so cookies are shared with the Laravel app. |
| `VerifyCsrfToken ($except, X-CSRF-TOKEN, X-XSRF-TOKEN)` | `VerifyCsrfTokenMiddleware(except: [...])` | 419 CSRF token mismatch.; the XSRF-TOKEN cookie is set on every response. |
| `SESSION_DRIVER=file\|database` | `SESSION_DRIVER=file\|database (array for tests)` | Laravel's sessions table (payload base64(serialize()), last_activity) and file format; extend() adds a driver. |
| `create_sessions_table migration` | `CreateSessionsTable` | Does nothing when the table exists already. |

## Permissions (daravel_permission)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `$user->assignRole('writer')` | `await user.assignRole('writer')` | **async**; spatie/laravel-permission's tables and morph types: shared with Laravel. |
| `$user->hasRole('admin\|writer')` | `await user.hasRole('admin\|writer')` | **async** |
| `$user->hasPermissionTo('posts.edit')` | `await user.hasPermissionTo('posts.edit')` | **async**; Throws PermissionDoesNotExist for unknown names, as Spatie. |
| `$user->syncRoles(['editor'])` | `await user.syncRoles(['editor'])` | **async** |
| `Role::create(['name' => 'writer'])` | `await Role.create('writer')` | **async** |
| `$role->givePermissionTo('posts.edit')` | `await role.givePermissionTo('posts.edit')` | **async** |
| `Route::middleware('role:admin\|editor')` | `.middleware(['role:admin\|editor'])` | Also permission: and role_or_permission:, with Spatie's 403 messages. |
| `php artisan permission:show` | `dartisan permission:show` |  |
| `app(PermissionRegistrar::class)->forgetCachedPermissions()` | `await PermissionRegistrar.current.forgetCachedPermissions()` | **async** |

## Excel and CSV (daravel_excel)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `class UsersExport implements FromQuery, WithHeadings, WithMapping` | `final class UsersExport implements FromQuery, WithHeadings, WithMapping` | Laravel Excel 3.1's concerns; a query is read a chunk at a time and the file streamed. |
| `return Excel::download(new UsersExport, 'users.xlsx')` | `return Excel.download(UsersExport(), 'users.xlsx')` |  |
| `Excel::store(new UsersExport, 'users.xlsx', 's3')` | `await Excel.store(UsersExport(), 'users.xlsx', disk: 's3')` | **async** |
| `Excel::import(new UsersImport, $request->file('file'))` | `await Excel.import(UsersImport(), (await request.file('file'))!)` | **async**; In one transaction; failures carry the sheet row. |
| `class UsersImport implements ToModel, WithHeadingRow, WithValidation` | `final class UsersImport with WithHeadingRow implements ToModel, WithValidation` |  |
| `$e->failures() (Maatwebsite\Excel\Validators\ValidationException)` | `e.failures (ExcelValidationException)` |  |
| `Excel::toArray(new UsersImport, 'users.xlsx')` | `await Excel.toArray('users.xlsx', headingRow: true)` | **async** |
| `Date::excelToDateTimeObject($value)` | `ExcelDate.toDateTime(value)` |  |
| `php artisan make:export UsersExport --model=User` | `dartisan make:export UsersExport --model=User` |  |

## Log viewer (daravel_log_viewer)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `composer require opcodesio/log-viewer (/log-viewer)` | `.withLogViewer(middleware: ['auth', 'can:view-logs'])` | Reads Daravel's JSON logs and Laravel's Monolog files from their end; 403 outside local without middleware. |

## Pulse (daravel_pulse)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `composer require laravel/pulse (/pulse)` | `.withPulse(middleware: ['auth', 'can:viewPulse'])` | Kept in memory by each isolate and merged through the coordinator, not in pulse_* tables; 403 outside local without middleware. |
| `PULSE_SLOW_QUERIES_THRESHOLD, PULSE_SLOW_REQUESTS_THRESHOLD, PULSE_SLOW_JOBS_THRESHOLD` | `the same .env keys` |  |

## Media library (daravel_medialibrary)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `class User extends Model implements HasMedia { use InteractsWithMedia; }` | `final class User extends Model with InteractsWithMedia (observers: [MediaObserver<User>()])` | spatie/laravel-medialibrary v11's media table and file layout; the observer deletes the media with the model. |
| `$user->addMedia($request->file('avatar'))->toMediaCollection('avatars')` | `await user.addMedia((await request.file('avatar'))!).toMediaCollection('avatars')` | **async** |
| `$this->addMediaCollection('avatars')->singleFile()` | `addMediaCollection('avatars').singleFile()` |  |
| `$this->addMediaConversion('thumb')->fit(Fit::Crop, 200, 200)->nonQueued()` | `addMediaConversion('thumb').fit(Fit.crop, 200, 200).nonQueued()` | Pure Dart (package:image): JPEG by default as Spatie; PNG, GIF, BMP and TIFF too, no WebP or AVIF encoding. |
| `$user->getFirstMediaUrl('avatars', 'thumb')` | `await user.getFirstMediaUrl('avatars', 'thumb')` | **async** |
| `$user->getMedia('documents')` | `await user.getMedia('documents')` | **async** |
| `$user->clearMediaCollection('avatars')` | `await user.clearMediaCollection('avatars')` | **async** |
| `$media->getUrl('thumb')` | `media.url('thumb')` |  |
| `$media->human_readable_size` | `media.humanReadableSize` |  |
| `php artisan media-library:regenerate` | `dartisan media:regenerate` |  |
| `php artisan media-library:clean` | `dartisan media:clean` |  |

## Activity log (daravel_activitylog)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `use LogsActivity; getActivitylogOptions()` | `with LogsActivity, observers: [ActivityLogObserver<T>()]` | spatie/laravel-activitylog v4's activity_log table: shared with Laravel. |
| `LogOptions::defaults()->logOnly([...])->logOnlyDirty()` | `LogOptions.defaults().logOnly([...]).logOnlyDirty()` |  |
| `activity('log')->performedOn($m)->causedBy($u)->log('...')` | `await activity('log').performedOn(m).causedBy(u).log('...')` | **async** |
| `activity()->withoutLogs(fn () => ...)` | `await ActivityLog.withoutLogs(() async {...})` | **async**; Scoped to the callback, not the whole process. |
| `LogBatch::withinBatch(fn ($uuid) => ...)` | `await LogBatch.within((uuid) async {...})` | **async** |
| `$model->activities` | `await model.activities().get()` | **async** |
| `Activity::inLog('x')->causedBy($u)->get()` | `await Activity.query().inLog('x').causedBy(u).get()` | **async** |
| `$activity->changes()` | `activity.changes` |  |
| `php artisan activitylog:clean` | `dartisan activitylog:clean` |  |

## Query filters (daravel_teorion)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Post::query()->filterAndPaginate($request)` | `await Post.definition.query().filterAndPaginate(request)` | **async**; laravel-teorion's request format: filters, scopes[], withs[], sort, is_paginate, pagination=cursor. |
| `Post::findFiltered($request, $id)` | `await Post.definition.query().findFiltered(request, id)` | **async** |
| `class PostQueryFilter extends QueryFilter` | `final class PostQueryFilter extends QueryFilter<Post>` |  |
| `Filter::multiLike(['title'])->alias('q')` | `Filter.multiLike(['title']).alias('q')` | default() is withDefault(); enum/in/null are enum_/in_/null_. |
| `FilterMacroRegistry::register('phone', fn ...)` | `FilterMacroRegistry.register('phone', (q, value, param, request) {...})` |  |
| `php artisan make:query-filter PostQueryFilter` | `dartisan make:query-filter Post` | Registered in bootstrap/query_filters.dart (no reflection). |

## Validation

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Validator::make($data, $rules)` | `Validator(data, rules)` |  |
| `'date_format:Y-m-d'` | `'date_format:Y-m-d' or Rules.dateFormat(['M d, Y'])` | createFromFormat('!' . $format) and the value must format back exactly, as Laravel. |
| `$validator->fails()` | `await validator.fails()` | **async** |
| `$validator->validate()` | `await validator.validate()` | **async** |
| `ValidationException` | `ValidationException` |  |
| `Rule::in([...]) / Rule::unique('users')` | `Rules.inList([...]) / Rules.unique('users')` |  |
| `['required', 'email', 'max:255']` | `Rules.required().email().max(255)` | Chained rule objects, checked by the compiler. |

## Eloquent

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `class User extends Model` | `final class User extends Model` |  |
| `protected $table / $fillable / $hidden / $casts` | `ModelDefinition<User>(table:, fillable:, hidden:, casts:)` |  |
| `'published_at' => 'datetime:Y-m-d H:i' (casts)` | `casts: {'published_at': Cast.dateTimeFormat('Y-m-d H:i')}` | PHP date() tokens, formatted in UTC as Laravel 8 to 13 do; formatPhpDate() for other values. |
| `php artisan model:show User` | `dartisan model:show User (models listed in bootstrap/models.dart)` | No class discovery: the registry is explicit, like migrations and jobs. |
| `$model->getMorphClass()` | `Relation.morphClassOf(User.definition)` | The morph alias, else `ModelDefinition.morphClass` (`App\Models\User` by default). |
| `User::query()` | `User.query()` |  |
| `User::where('a', $b)->first()` | `await User.query().where('a', b).first()` | **async** |
| `User::find($id) / findOrFail($id)` | `await User.query().find(id) / findOrFail(id)` | **async**; throws `ModelNotFoundException` |
| `->firstOrFail()` | `.firstOrFail()` | **async**; throws `ModelNotFoundException` |
| `User::create($attributes)` | `await User.query().create(attributes)` | **async** |
| `User::firstOrCreate / updateOrCreate` | `firstOrCreate / updateOrCreate` | **async**; Through createOrFirst, as Laravel 12: a concurrent create returns the winner's row. |
| `User::createOrFirst($attributes, $values)` | `await User.query().createOrFirst(attributes, values)` | **async**; In a savepoint inside a transaction. |
| `catch (UniqueConstraintViolationException $e)` | `on UniqueConstraintViolationException catch (e)` | Extends QueryException (sql, bindings, connectionName, previous); the message keeps the ? placeholders. |
| `->with(['posts'])` | `.with_(['posts'])` | `with` is a reserved word in Dart. |
| `->with('user:id,name')` | `.with_('user:id,name')` | Keys the relation matches on are added when the selection leaves them out. |
| `->withCount('posts')` | `.withCount('posts')` |  |
| `->withSum('orders', 'total') / withAvg / withMin / withMax / withExists` | `.withSum('orders', 'total') / withAvg / withMin / withMax / withExists` |  |
| `->whereHas('posts', fn)` | `.whereHas('posts', (q) {...})` |  |
| `->whereHas('posts.comments', fn) / whereDoesntHave / orWhereHas` | `.whereHas('posts.comments', (q) {...})` | Nested relations become nested EXISTS, as in Laravel. |
| `->whereHasMorph('commentable', [Post::class], fn)` | `.whereHasMorph('commentable', [Post.definition], (q, type) {...})` |  |
| `$this->hasOneThrough(Owner::class, Car::class)` | `HasOneThrough<Owner>(() => Owner.definition, through: () => Car.definition, firstKey: 'mechanic_id', secondKey: 'car_id')` |  |
| `$this->morphMany(Comment::class, 'commentable')` | `MorphMany<Comment>(() => Comment.definition, morphName: 'commentable')` |  |
| `$this->morphOne(Image::class, 'imageable')` | `MorphOne<Image>(() => Image.definition, morphName: 'imageable')` |  |
| `$this->morphTo()` | `MorphTo(types: [() => Post.definition, () => Video.definition])` | No reflection: possible targets come from `types:` or the morph map. |
| `$this->morphToMany(Tag::class, 'taggable') / morphedByMany` | `MorphToMany<Tag>(..., morphName: 'taggable', relatedPivotKey: 'tag_id') / MorphedByMany` |  |
| `Relation::morphMap([...]) / enforceMorphMap([...])` | `Relation.morphMap({'post': () => Post.definition}) / enforceMorphMap` |  |
| `->paginate(15)` | `await query.paginate(perPage: 15)` | **async**; Page and path come from the current request, like Laravel. |
| `->simplePaginate() / cursorPaginate()` | `.simplePaginate() / .cursorPaginate()` | **async** |
| `->latest() / oldest()` | `.latest() / .oldest()` |  |
| `->withTrashed() / onlyTrashed()` | `.withTrashed() / .onlyTrashed()` |  |
| `$model->save() / update() / delete()` | `await model.save() / update() / delete()` | **async** |
| `$model->restore() / forceDelete()` | `await model.restore() / forceDelete()` | **async** |
| `$model->isDirty() / wasChanged()` | `model.isDirty() / wasChanged()` |  |
| `$model->getChanges()` | `model.getChanges()` |  |
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
| `DB_CONNECTION=mysql / mariadb` | `withDatabaseDriver('mysql', MySqlDriver.fromConfig)` | package:daravel_mysql; registered by new projects. |
| `DB::connection('legacy')->table('orders')` | `DB.table('orders', connection: 'legacy')` |  |
| `DB_URL=postgres://user:pass@host/db (ConfigurationUrlParser)` | `DB_URL, ConnectionConfig.withUrl(url)` | Merged like Laravel 12: URL parts replace DB_* values, the rest stay. |
| `'connections' => ['legacy' => ['url' => env('LEGACY_DB_URL')]]` | `withDatabaseConnection('legacy', (env) => ConnectionConfig.fromUrl(env.string('LEGACY_DB_URL')))` |  |
| `DB::connection('legacy')->transaction(fn)` | `DB.transaction(() async {...}, connection: 'legacy')` | **async**; Transactions are per connection, as in Laravel. |
| `DB::raw($sql)` | `DB.raw(sql)` |  |
| `DB::listen(fn (QueryExecuted $q) => ...)` | `DB.listen((QueryExecuted q) {...})` |  |
| `DB::whenQueryingForLongerThan(500, fn)` | `DB.whenQueryingForLongerThan(const Duration(milliseconds: 500), (q) {...})` | Total per request, job or command; once. |
| `DB::enableQueryLog(); ... count(DB::getQueryLog())` | `final (result, count, queries) = await DB.withQueryCount(() => ...)` |  |
| `->whereToday('starts_at') / wherePast / whereFuture / whereBeforeToday` | `.whereToday('starts_at') / wherePast / whereFuture / whereBeforeToday` | Against Clock.now(). |
| `->insertGetId($values)` | `await DB.table(t).insertGetId(values)` | **async** |
| `->upsert($values, $uniqueBy)` | `.upsert(values, uniqueBy)` | **async** |
| `->chunkById(100, fn)` | `.chunkById(100, (rows) async {...})` | **async** |
| `->lazy(500) / ->cursor()` | `.lazy(500)` | A stream of rows read a page at a time; order the query. |
| `response()->streamJson(['data' => $query->cursor()])` | `Response.stream(query.streamJson(), contentType: 'application/json')` | The rows as the bytes of one JSON array, a page at a time, without building models; or `Response.streamJson(query.lazy(), wrap: 'data')`. |
| `->toSql() / toRawSql()` | `.toSql() / .toRawSql()` |  |
| `->selectSub($query, 'alias')` | `.selectSub(query, 'alias')` |  |

## Schema & migrations

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `->selectSub($query, 'alias')` | `.selectSub(query, 'alias')` |  |
| `Schema::create('users', fn (Blueprint $table) => ...)` | `schema.create('users', (table) {...})` | **async** |
| `Schema::table / dropIfExists / hasTable / hasColumn` | `schema.table / dropIfExists / hasTable / hasColumn` | **async** |
| `$table->id() / string() / foreignId()->constrained()` | `table.id() / string() / foreignId().constrained()` |  |
| `$table->morphs('taggable') / nullableMorphs / uuidMorphs / ulidMorphs` | `table.morphs('taggable') / nullableMorphs / uuidMorphs / ulidMorphs` |  |
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
| `Crypt::encrypt / decrypt` | `await Crypt.encrypt / decrypt` | **async**; PHP serialize() inside, as Laravel: maps and lists are arrays on both sides. |
| `php artisan env:encrypt / env:decrypt` | `dartisan env:encrypt / env:decrypt` | Same .env.encrypted file (default and --readable); decrypted in memory at boot with DARAVEL_ENV_ENCRYPTION_KEY or LARAVEL_ENV_ENCRYPTION_KEY. |
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
| `Cache::tags(['people'])->put($key, $value, $ttl)` | `await Cache.tags(['people']).put(key, value, ttl: ttl)` | **async**; memory, process and redis stores (Laravel's layout on Redis); file and database cannot tag, as in Laravel. |
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
| `->timezone('America/New_York')` | `.timezone('America/New_York')` |  |
| `config('app.schedule_timezone')` | `SCHEDULE_TIMEZONE` | No fallback to APP_TIMEZONE in 1.x (doctor warns). |

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
| `Storage::disk('s3')->temporaryUrl($path, now()->addMinutes(30))` | `Storage.disk('s3').temporaryUrl(path, expiration: 30.minutes.fromNow)` | package:daravel_s3 (withS3()); same AWS_* variables. |
| `Storage::disk('s3')->temporaryUploadUrl($path, $expiration)` | `Storage.disk('s3').temporaryUploadUrl(path, expiration: ...)` | Returns url and headers, as Laravel's array. |
| `Http::withToken($t)->retry(3, 100)->post($url, $data)` | `await Http.withToken(t).retry(3).post(url, json: data)` | **async** |
| `Http::fake([...]) / Http::assertSent(...)` | `Http.fake({...}).assertSent(...)` |  |
| `php artisan down --secret / up` | `dartisan down --secret / up` | Same storage/framework/down file; bypass cookie daravel_maintenance. |
| `Log::info($message, $context)` | `Log.info(message, context)` |  |
| `Log::withContext([...])` | `Log.withContext({...})` |  |
| `config('app.name')` | `Config.get<String>('app.name')` |  |
| `app(Service::class)` | `App.make<Service>()` |  |
| `resolve(Service::class)` | `inject<Service>() / maybeInject<Service>()` | The type is inferred where the value goes: `orders ?? inject()`. |
| `$this->app->singleton(...) in AppServiceProvider::register()` | `.withBindings((c) => c.singleton((c) => OrderService(c(), c())))` | Calling the container (`c()`) resolves the type each argument needs. |
| `now()` | `Clock.now()` | Frozen by freezeTime()/travel() in tests. |

## Localization

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `__('auth.failed') / trans('auth.failed', ['name' => $name])` | `trans('auth.failed', {'name': name})` | No __: a leading underscore makes a Dart name private. |
| `trans_choice('apples', $count)` | `transChoice('apples', count)` | Laravel's plural rules for 280 locales. |
| `Lang::get / Lang::has` | `Lang.get / Lang.has` |  |
| `App::setLocale('id') / App::getLocale()` | `App.setLocale('id') / App.locale` | Per request, job or command scope. |
| `lang/id.json` | `lang/id.json (loaded at boot)` |  |

## Feature flags (Pennant)

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Feature::define('beta', fn (User $user) => ...)` | `Feature.define('beta', (scope) => ...)` |  |
| `Feature::active('beta') / Feature::value('beta')` | `await Feature.active('beta') / Feature.value('beta')` | **async** |
| `Feature::for($team)->active('beta')` | `Feature.forScope(team).active('beta')` | `for` is a Dart keyword. |
| `Feature::activateForEveryone('beta')` | `Feature.activateForEveryone('beta')` |  |
| `EnsureFeaturesAreActive::using('beta')` | `'feature:beta'` | Same features table, scope format and 400 response. |

## Strings, helpers, collections

| Laravel | Daravel | Notes |
| :-- | :-- | :-- |
| `Str::slug / snake / camel / studly / kebab / title / headline` | `Str.slug / snake / camel / studly / kebab / title / headline` |  |
| `Str::limit / words / mask / squish` | `Str.limit / words / mask / squish` |  |
| `Str::after / before / between / start / finish` | `Str.after / before / between / start / finish` |  |
| `Str::contains / startsWith / endsWith` | `Str.contains / startsWith / endsWith` |  |
| `Str::plural / singular / pluralStudly` | `Str.plural / singular / pluralStudly` | English rules with common irregulars. |
| `Str::random / uuid / ulid / isUuid / isJson` | `Str.random / uuid / ulid / isUuid / isJson` |  |
| `Str::of($title)->after(':')->squish()->slug()` | `title.after(':').squish().slug()` | Str methods chain on the string itself. |
| `now()->addMinutes(10) / Carbon::now()->subDays(7)` | `10.minutes.fromNow / 7.days.ago` |  |
| `$date->diffForHumans() / isPast() / isToday() / startOfDay()` | `date.diffForHumans() / isPast / isToday / startOfDay` | Carbon's units and wording, en and id. |
| `$date->addMonth() / addMonthsNoOverflow(1) / startOfWeek() / between($a, $b)` | `date.addMonths(1) / addMonthsNoOverflow(1) / startOfWeek / isBetween(a, b)` | Same overflow rules as Carbon. |
| `Context::add('tenant_id', $id) / Context::get('tenant_id') / addHidden` | `Context.add('tenant_id', id) / Context.get<int>('tenant_id') / addHidden` | Logged, and carried into queued jobs. |
| `Number::format / percentage / currency / fileSize / abbreviate / ordinal` | `Number.format / percentage / currency / fileSize / abbreviate / ordinal` | en and id locales, as Laravel's intl output. |
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
| `cache.headers` | `cache.headers` |
| `Laravel\Pennant\Middleware\EnsureFeaturesAreActive` | `feature` |

## Not available yet

| Laravel | Plan |
| :-- | :-- |
| Sessions, CSRF, SPA cookie auth | Tier 2 |
| optional() helper | Not planned: Dart has ?. and ?? |
| app() / route() / url() global helpers | Use App.make<T>(), router.url(...); a global app() would be shadowed by the idiomatic app variable |
| dd() / dump() | Not planned: use print or Log in development |
