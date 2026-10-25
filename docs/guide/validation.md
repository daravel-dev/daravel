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

Rule objects also chain, so the compiler checks names and arguments:

```dart
.rules({
  'email': Rules.required().string().email().max(255).unique('users'),
  'age': Rules.nullable().integer().min(18),
  'avatar': Rules.nullable().image().max(2048),
})
```

Any `Rules.x()` starts a chain, each step adds the rule of the same name, and
a chain validates, reports and documents (OpenAPI) exactly like the matching
string. Strings, rule objects and chains mix freely in one list.

Rule strings are parsed when the route or request is defined, so a typo fails
at boot or in the first test; `dartisan lint` (`invalid_validation_rule`)
reports it earlier, with the line, including a missing argument such as
`max` without a value.

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

Declare it on the route with `.validates(const StorePostRequest())` instead
and read `request.validated()` in the handler; see
[Routing](routing.md#declared-validation-and-responses).

## File uploads

`multipart/form-data` bodies are parsed as they arrive: fields become input
like a form, and each file is streamed to a temporary file (deleted after the
response) and appears as an `UploadedFile`. Names such as `photos[]` and
`user[avatar]` nest as in Laravel.

```dart
router.post('/avatar', (request) async {
  final data = request.validated();
  final path = await data.file('avatar').store('avatars', disk: 'public');
  return {'url': Storage.disk('public').url(path)};
}).rules(const {'avatar': 'required|image|max:2048'});
```

- `request.file('avatar')`, `request.hasFile('photos')` and
  `request.uploadedFiles()` read the uploads; `all()` includes them.
- `UploadedFile`: `clientName`, `clientExtension`, `clientMimeType` (sent by
  the client, not trusted), `mimeType` and `extension` (detected from the
  content), `size`, `bytes()`, `text()`, `openRead()`, `hashName()`,
  `store(directory, disk:)` and `storeAs(directory, name, disk:)`.
- Rules, as in Laravel 12: `file`, `image` (jpg, jpeg, png, gif, bmp, webp;
  `image:allow_svg` adds SVG), `mimes:pdf,docx` (the extension of the
  detected type), `mimetypes:image/*`, `extensions:csv,txt` (the client's
  file name), and `min`, `max`, `size`, `between` in kilobytes. PHP files are
  refused unless `php` is listed.
- Types are detected from the content (PDF, images, Office and OpenDocument
  files, archives, text), never from the file name: a text file named
  `photo.png` is not an image.
- The body size limit of `BodyLimitsMiddleware` (50 MiB by default) covers
  uploads; a request also accepts at most 1 000 fields and 20 files.

In tests, send files with `client.post(uri, files: {...})` (or
`Request.fake(files: ...)`) and build them with `UploadedFile.fake`:

```dart
await client.post('/api/avatar', files: {
  'avatar': UploadedFile.fake.image('me.png', kilobytes: 120),
  'photos': [UploadedFile.fake.image('1.png'), UploadedFile.fake.image('2.gif')],
});
```
