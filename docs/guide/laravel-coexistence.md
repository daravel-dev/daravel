# Laravel coexistence

Daravel's product goal is that a Laravel app and a Daravel app can run side
by side on the same database, and that a codebase can move in either
direction. That works because the formats both sides read and write are
Laravel's, and the **conformance suite** locks them:

- `packages/daravel/test/conformance/` runs every contract below against
  the framework (`dart test --tags conformance`);
- the fixtures cite the Laravel 12 / Sanctum 4 source they come from
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

## What is shared, and how

| Area | Contract |
| :-- | :-- |
| `migrations` table | `id`, `migration`, `batch`; framework migrations use Laravel's names (`0001_01_01_000001_create_cache_table`, ...) |
| `users` | Laravel 12 skeleton columns |
| `cache`, `cache_locks` | Laravel 12 schema, including the `expiration` indexes |
| `jobs`, `job_batches`, `failed_jobs` | Laravel 12 schema |
| `personal_access_tokens` | Sanctum 4 schema; tokens `{id}\|{40 chars}{crc32b}`, SHA-256 stored; `tokenable_type` = `App\Models\User` |
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

## Not shared yet

Sessions, CSRF and cookies (Tier 2), queue payloads (both sides can share
the `jobs` table only when each consumes its own queue names), MySQL (Tier 2).
The [parity table](parity.md) lists every mapped API and what is missing.
