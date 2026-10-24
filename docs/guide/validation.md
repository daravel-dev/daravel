# Validation

Validate a request inline with Laravel's rule strings, or with typed rule
objects from `Rules`:

```dart
final data = await request.validate({
  'email': 'required|email|unique:users',
  'password': 'required|min:8|confirmed',
  'role': [Rules.required(), Rules.inList(['admin', 'editor'])],
  'tags.*': 'string|max:20',
});
data.string('email'); // typed access to validated input only
```

Failures throw `ValidationException`, rendered as Laravel's 422 body:

```json
{
  "message": "The email field is required. (and 1 more error)",
  "errors": {
    "email": ["The email field is required."],
    "password": ["The password field must be at least 8 characters."]
  }
}
```

The default English messages are identical to Laravel 12's
`lang/en/validation.php` (checked by the conformance suite against the
upstream file). Indonesian ships as the second locale: set
`request.attributes['locale'] = 'id'` (for example in a middleware).

## Semantics locked to Laravel

- `nullable` stops the remaining rules when the value is `null`.
- A field that is absent and not `required` skips non-implicit rules;
  `sometimes` validates only when the key is present.
- `confirmed` looks for `{field}_confirmation`.
- `bail` stops at the first failure of a field.
- Nested data uses dot paths and `*` wildcards.

## Form requests

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#form-request -->
```dart
final class StorePostRequest extends FormRequest {
  const StorePostRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'title': 'required|string|max:120',
    'body': 'nullable|string',
    'published': [Rules.sometimes(), Rules.boolean()],
  };
}
```
<!-- /include -->

`await FormRequest.run(const StorePostRequest(), request)` runs
`authorize()` (403 when it returns `false`), then the rules, and returns the
validated data. `dart run bin/dartisan.dart make:request StorePostRequest`
creates one.
