# Laravel coexistence

Daravel's product goal is that a Laravel app and a Daravel app can run side
by side on the same database, and that a codebase can move in either
direction. That works because the formats both sides read and write are
Laravel's, and the **conformance suite** locks them:

- `packages/daravel/test/conformance/` runs every contract below against
  the framework (`dart test --tags conformance`);
- the fixtures cite the Laravel 13 / Sanctum 4 source they come from (Laravel
  10 to 12 write the same formats, ADR-025)
  (`packages/daravel_test/lib/src/conformance/`), and the validation
  messages are generated from Laravel's `lang/en/validation.php`
  (`dart run tool/conformance/sync_laravel_messages.dart`);
- applications get the same matchers from
  `package:daravel_test/conformance.dart`.

## Settings for a shared database

```dotenv
APP_KEY=base64:...        # the same key as the Laravel app
```

That is all: Daravel's defaults are Laravel's (ADR-024), `APP_CIPHER=AES-256-CBC`
and `HASH_DRIVER=bcrypt`. If the Laravel app changed them, set the same values.

### Older Laravel versions

Laravel 10, 11, 12 and 13 send the same validation messages, 422 summary
and 404/405 messages, so they need nothing more. For an application on an
older Laravel, whose clients may show these strings or compare them, set
its major version:

```dotenv
COMPAT_LARAVEL_VERSION=8
```

| `COMPAT_LARAVEL_VERSION` | Validation message | 422 `message` | Unknown route (404) | Wrong verb (405) |
| :-- | :-- | :-- | :-- | :-- |
| `10` to `13` (default `12`) | `The email field must be a valid email address.` | first error + `(and N more errors)` | `The route api/x could not be found.` | `... not supported for route api/x. ...` |
| `9` | `The email must be a valid email address.` | as 10 | as 10 | as 10 |
| `8` | as 9 | `The given data was invalid.` | empty | `... not supported for this route. ...` |

Messages the application sets itself (`messages:` or translations) are
used as they are. `Response.json(data, phpCompatible: true)` writes the
bytes PHP's `json_encode()` would (`\/`, `\u` escapes, `[]` for an empty
map), for clients that compare or sign a response body.

Model JSON needs no version switch: Laravel 8 to 13 serialize a model the
same way, and `Model.toJson` follows them. An `appends:` entry that names
an existing attribute replaces it in place (same key position), and a
`datetime:FORMAT` cast, `Cast.dateTimeFormat('Y-m-d H:i:s')` in Daravel,
is written in that PHP `date()` format in UTC, as Laravel writes a
formatted `created_at` (it serializes timestamps to UTC before formatting
them). Dates without a format stay ISO-8601 UTC (`Carbon::toJSON()`).

## What is shared, and how

| Area | Contract |
| :-- | :-- |
| `migrations` table | `id`, `migration`, `batch`; framework migrations use Laravel's names (`0001_01_01_000001_create_cache_table`, ...) |
| `users` | Laravel 13 skeleton columns |
| `cache`, `cache_locks` | Laravel 13 schema, including the `expiration` indexes |
| `jobs`, `job_batches`, `failed_jobs` | Laravel 13 schema |
| `personal_access_tokens` | Sanctum 4 schema; tokens `{id}\|{40 chars}{crc32b}`, SHA-256 stored; `tokenable_type` = `App\Models\User` |
| `notifications` | Laravel 13 schema; `type` `App\Notifications\...`, `notifiable_type` the model's `morphClass`, `data` JSON ([Mail](mail.md)) |
| `features` | Pennant's schema and scope serialization ([Feature flags](feature-flags.md)) |
| Broadcasting | Laravel Reverb's Pusher protocol: Echo connects to Daravel, `/broadcasting/auth` signs as Laravel does, Laravel broadcasts through Daravel and Daravel through Reverb, notifications on `private-App.Models.User.{id}` ([Broadcasting](broadcasting.md)) |
| Passwords | bcrypt `$2y$` both ways (argon2id hashes need PHP's argon2 support) |
| `Crypt` strings | `base64(json{iv, value, mac, tag})`, AES-256-CBC + HMAC or AES-256-GCM |
| JSON errors | 401/403/404/405/413/422/429/500 bodies and messages, see [Responses](responses.md) |
| Pagination | `paginate`, `simplePaginate`, `cursorPaginate` bodies, link window, cursor encoding |
| Resources | `{data}`, `{data, links, meta}` |
| Dates | `2026-01-02T03:04:05.000000Z` |
| Routes | `apiResource` names, URIs and parameters |

## Deliberate differences

| Laravel | Daravel | Why |
| :-- | :-- | :-- |
| `Crypt::encrypt()` uses PHP `serialize()` | JSON | No PHP serializer yet (Tier 2); use the `*String` variants across runtimes |
| `HASH_VERIFY` rejects any other driver | accepts bcrypt and argon2id across a switch | Lets `rehashPasswordIfRequired` upgrade old hashes (ADR-024) |
| JSON escapes `/` and non-ASCII (`\/`, `é`) | plain UTF-8 | Equivalent after decoding; cursors use PHP's escaping |
| `$model->with(...)` | `with_(...)` | `with` is reserved in Dart |
| URL rule accepts any length | rejects > 8 192 chars | Bounded validation time (security suite) |
| `QueryException` writes the bindings into its message | keeps the `?` placeholders | Values (password hashes, emails) stay out of logs; they are in `bindings` |

## Where Dart differs from PHP by design

Some Laravel idioms cannot exist in an AOT-compiled, statically typed
language. Daravel keeps the intent and changes the mechanism:

| Laravel (PHP) | Why it cannot carry over | Daravel |
| :-- | :-- | :-- |
| Synchronous I/O: `User::find(1)` | Dart runs I/O on an event loop | `await User.query().find(1)` |
| Magic properties and methods (`__get`, `__call`) | No reflection in AOT binaries (`dart:mirrors` is unavailable) | Typed accessors written by `dartisan make:model` / `model:sync` |
| Autoloading and folder scanning | The AOT compiler drops code that `main()` never imports | Explicit registries in `bootstrap/`, maintained by `make:*` and checked by `dartisan lint` |
| Injected controller parameters (`store(StoreRequest $r, User $u)`) | Signatures cannot be introspected at runtime | Handlers take a `Request`; `FormRequest.run`, `request.param<T>()` and route model binding |
| One `array` type and loose comparison | Sound null safety; `List` and `Map` are distinct types | Typed `ValidatedData`, maps and lists |
| `eval` and queued closures | No compiler in the binary; closures cannot cross processes | Jobs are `Job` classes registered in `bootstrap/jobs.dart` |
| Server-driven reflective UI (Livewire, Filament, Nova) | Depends on reflective property hydration | Flutter (web, mobile, desktop) or an SPA over the JSON API |

## Not shared yet

Sessions, CSRF and cookies (Tier 2).

**Queues.** Both frameworks can use one `jobs` table, but each runs only its
own jobs: Laravel's payloads carry a PHP-serialized command and Daravel's a
registered Dart job. Daravel workers recognise Laravel jobs and skip them
without touching them (no reservation, `attempts` unchanged, logged once), so
a Laravel worker still processes them. Laravel workers cannot do the same for
Daravel jobs, so give Daravel its own queue names, for example
`Queue.dispatch(job).onQueue('daravel')` with `dartisan queue:work
--queue=daravel`, and keep Laravel's `queue:work` on its own queues.
The [parity table](parity.md) lists every mapped API and what is missing.
To move an application over endpoint by endpoint, see
[Migrating from Laravel](migrating-from-laravel.md).
