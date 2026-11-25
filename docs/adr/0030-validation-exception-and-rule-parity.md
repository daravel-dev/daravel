# ADR-030: Validation exception type and rule parity

- **Status:** accepted 2026-11-25.
- **Context:** Daravel and Laravel are meant to run side by side, and an application that validates the same payload in both expects the same answer. Two things decide how closely that holds: what type a failed validation is thrown as, and how each rule reads its input. This record fixes the first for the whole 1.x line and records one rule where the two differ today, so neither is left to be found by accident.

## Decision

### 1. `ValidationException` stays an `HttpException` throughout 1.x

`ValidationException` (`packages/daravel/lib/src/validation/validation_exception.dart`) extends `HttpException`. The code builds it as follows:

- **Status:** always `422`. The constructor passes `422` to `HttpException`, so `status` is `422` and `headers` is empty.
- **Message:** the first error plus how many more, as Laravel 9 to 13 writes it (`The name field is required. (and 1 more error)`); `The given data was invalid.` for `COMPAT_LARAVEL_VERSION=8` or an empty error map.
- **Errors:** `errors`, an unmodifiable map from attribute (`items.0.id`) to its list of messages.
- **Default response:** the exception handler checks for `ValidationException` before `HttpException` and answers `Response.json(toJson(), status: 422)`, a body of `{"message": "...", "errors": {"field": ["..."]}}`. It is not pretty-printed, which matches Laravel's 422 body, whereas other HTTP errors are.
- **Reporting:** like any `HttpException` below 500, it is not logged by default.

Laravel's `Illuminate\Validation\ValidationException` extends `Exception`, not an HTTP exception (`src/Illuminate/Validation/ValidationException.php`, 12.x, line 9). Daravel's differs, and separating the two types would be the cleaner model. It is also a change of a public type relationship: any code that catches or matches `HttpException`, or registers `handler.render<HttpException>(...)`, receives 422 validation failures today and would stop receiving them. That is a breaking change, so it can only happen in a major version. It is not made in 1.x and is a candidate for 2.0.

**What an application can rely on until then:**

- `ValidationException` is an `HttpException`, so `catch (HttpException e)`, `e is HttpException` and a renderer or reporter registered for `HttpException` keep receiving validation failures, with `status == 422`.
- The default response is the 422 JSON above, and the shape of `toJson()` does not change.
- `ValidationException`, `errors`, `withMessages` and `summarize` keep their names and meaning.
- Code that wants to treat validation failures apart from other HTTP errors should test for `ValidationException` first (or register its renderer for it: the first matching renderer wins). That ordering stays correct if the types are separated in 2.0.

### 2. Rule parity: `boolean` accepts more than Laravel

Laravel 12.x `validateBoolean` (`src/Illuminate/Validation/Concerns/ValidatesAttributes.php`, branch `12.x`, lines 494 to 503):

```php
$acceptable = [true, false, 0, 1, '0', '1'];

if (($parameters[0] ?? null) === 'strict') {
    $acceptable = [true, false];
}

return in_array($value, $acceptable, true);
```

The comparison is strict, so only those exact values pass, and `boolean:strict` passes only `true` and `false`. A PHP 8.4 run of `in_array($v, [true, false, 0, 1, '0', '1'], true)` gives `false` for `'true'`, `'false'`, `1.0`, `0.0` and `'yes'`.

Daravel's `BooleanRule` (`packages/daravel/lib/src/validation/rules.dart`) reads its input through `BooleanRule.asBool`, which accepts `true`, `false`, `1`, `0`, `'1'`, `'0'`, `'true'` and `'false'`. A run of `Validator({'f': value}, {'f': 'boolean'})` on Daravel 1.27.7 gives:

| Input | Laravel 12.x `boolean` | Daravel `boolean` | Laravel `boolean:strict` | Daravel `boolean:strict` |
| :-- | :-- | :-- | :-- | :-- |
| `true`, `false` | passes | passes | passes | passes |
| `1`, `0`, `'1'`, `'0'` | passes | passes | fails | passes |
| `'true'`, `'false'` | fails | **passes** | fails | **passes** |
| `1.0`, `0.0` (a JSON `1.0` decodes to a double) | fails | **passes** | fails | **passes** |
| `'yes'` | fails | fails | fails | fails |

So Daravel differs from Laravel in three ways:

- **`'true'` and `'false'`** pass. This is written in the code (`asBool` documents it) and is the difference this record is about.
- **`1.0` and `0.0`** pass, because the `switch` in `asBool` matches `1` and `0` as constant patterns, which compare with `==`, and `1.0 == 1` in Dart. PHP's strict comparison rejects them. This is an observation of the code's behaviour; this record does not say whether it was intended.
- **`boolean:strict`** is not implemented: the rule parser ignores arguments for `boolean`, so `boolean:strict` behaves as plain `boolean` and accepts everything in the second column. (`bool` is an alias of `boolean` in both: Laravel maps `Bool` to `Boolean` in `ValidationRuleParser::normalizeRule`.)

`validated()` and the typed accessors read the same way (`ValidatedData.boolean`, `maybeBoolean`), so a value that passes the rule is read back as the matching `bool`.

**Who is affected:** an application that validates the same payload in Laravel and in Daravel side by side gets different answers. `"true"` and `"false"` are a valid boolean in Daravel and a 422 in Laravel. The same holds for `1.0`, and for `boolean:strict` on `1`, `0`, `'1'` and `'0'`.

**Status of the deviation:** these are KNOWN deviations, and they stay through 1.28.x. Tightening `boolean` turns requests that pass today into 422 responses, which is not a change to make quietly in a minor release. Whether and how to align is left open and will be decided in a later revision of this ADR: for example a configuration switch that selects Laravel's list, or the change in 2.0. Until then:

- Do not rely on `'true'` or `'false'` passing `boolean` if the same request must also pass in Laravel; send JSON `true` and `false`, or `1` and `0`.
- `boolean:strict` does not give Laravel's answer in Daravel today (see above); a custom `Rule` is the way to get an exact match.

### 3. Rule parity policy

A rule's behaviour changes toward Laravel in a minor release only when:

- the difference is proven against the Laravel source (cited by file, method and branch or tag) and against a real PHP run of the same input; and
- the change ships with an upgrade note in the changelog.

A difference whose fix would reject input that is accepted today is recorded in an ADR first, together with who is affected, and the fix waits for the decision there. Until then it is also named in the `note:` of the rule's row in `parity.yaml`, so the parity page shows it.

## Consequences

- `docs/guide/parity.md` lists the `boolean` rule with a note that points here.
- Nothing in `lib/` changes with this record.
- A later revision of this ADR decides the `boolean` alignment; if it changes behaviour, it ships with an upgrade note.
