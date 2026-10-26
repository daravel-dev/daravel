# Flutter client

`dartisan client:flutter` generates a typed Dart client package from your
routes. The package is plain Dart on `package:http`, so it works in a
Flutter app (mobile and desktop) and in Dart command-line tools. Because the
server and the app share a language, the client is built from the server's
own route table and validation rules, not from a hand-written spec, and you
don't need `build_runner`.

```bash
dart run bin/dartisan.dart client:flutter --output=../mobile/packages/app_client
```

| Option | Default | Meaning |
| :-- | :-- | :-- |
| `--output` | `../app_client` | Directory of the package, relative to the app |
| `--package-name` | `app_client` | Package name, also the client class (`AppClient`) |
| `--prefix` | `/api` | Only routes under this path (`/` for all) |
| `--base-url` | `APP_URL` | Default base URL of the client |
| `--locale` | `APP_LOCALE` | Language of the validation messages |

Add it to the Flutter app with a path dependency (`app_client: {path:
packages/app_client}`) and run the command again whenever the routes
change. Generated files are overwritten. `pubspec.yaml` and
`analysis_options.yaml` are written only once, so you can add to them.

## What comes from where

The command boots the application like `openapi:generate` and reads each
route's metadata ([Routing](routing.md#declared-validation-and-responses)):

| On the route | In the client |
| :-- | :-- |
| `.name('users.store')` | `api.users.store(...)`; a one-segment name such as `ping` is a method on the client itself |
| `{id}` with `.whereNumber('id')` | a positional `int id` (other parameters are `String`) |
| `.validates(FormRequest)` / `.rules({...})` | named parameters typed from the rules, plus an input class with the rules checked on the device |
| `.returns(schema, name: 'User')` | a `User` model with `fromJson` and `toJson`; date-time strings are `DateTime` |
| `shape: .paginated` / `.simplePaginated` / `.cursorPaginated` | `Page<User>`, `SimplePage<User>`, `CursorPage<User>` and a `page` or `cursor` parameter |
| `shape: .collection` | `List<User>` |
| `file` rules | `http.MultipartFile` parameters, sent as `multipart/form-data` |
| `router.ws(...)` | a method returning the `ws://` / `wss://` URL |
| no metadata | `Future<Object?>` with a `body` or `query` map |

```dart
final api = AppClient(baseUrl: 'https://api.example.com');

final user = await api.users.store(
  name: 'Teo',
  email: 'teo@example.com',
  password: 'Secret123',
  passwordConfirmation: 'Secret123',
);

final Page<User> page = await api.users.index(page: 2);
print('${page.items.length} of ${page.total}');
```

## Errors

Laravel's error bodies become exceptions:

| Status | Exception | Useful fields |
| :-- | :-- | :-- |
| 422 | `ValidationException` | `errors` per field, `first('email')` |
| 401 | `UnauthenticatedException` | |
| 429 | `TooManyRequestsException` | `retryAfter` |
| other 4xx/5xx | `ApiException` | `status`, `message`, `body` |

```dart
try {
  await api.users.store(...);
} on ValidationException catch (e) {
  setState(() => emailError = e.first('email'));
}
```

## Validation on the device

Each input class has the server's rules as `static const rules`, a
`validate()` method returning the messages per field, and one
`validate<Field>` function per field that fits `TextFormField.validator`:

```dart
TextFormField(
  decoration: const InputDecoration(labelText: 'Email'),
  validator: UsersStoreInput.validateEmail,
);
```

The messages are not translated a second time. They were resolved by the
server's translator when the client was generated, with the form request's
`attributes()` and `messages()`, so they read exactly like the 422 the
server would send. The rule semantics are copied from the server too. They
cover empty values, `nullable`, `sometimes` and `bail`, and `min`/`max`
choose the string, numeric or array message by the value's type, as on the
server. The generator's test runs both on the same inputs and expects the
same messages.

Rules that need the server, such as `unique`, `exists`, dates, files, closures
and wildcard (`tags.*`) rules, are left out. The input class lists them
("Checked by the server only"), and so does the command's output. The
server stays the authority: a client that passes still gets a 422 when, for
example, the email is taken.

`confirmed` compares two fields, so a single-field validator skips it unless
you pass the other values: `validatePassword(value, {'password_confirmation':
confirmController.text})`. `validate()` on the whole input includes it.

## Tokens

Requests send `Authorization: Bearer <token>` when the client's `TokenStore`
has one. The default `MemoryTokenStore` forgets the token when the app
restarts. Implement `TokenStore` over `flutter_secure_storage` to keep it:

```dart
final class SecureTokens implements TokenStore {
  const SecureTokens(this.storage);
  final FlutterSecureStorage storage;
  @override
  Future<String?> read() => storage.read(key: 'token');
  @override
  Future<void> write(String? token) => token == null
      ? storage.delete(key: 'token')
      : storage.write(key: 'token', value: token);
}

final api = AppClient(tokens: SecureTokens(const FlutterSecureStorage()));
final login = await api.auth.login(body: {'email': email, 'password': password});
await api.tokens.write((login! as Map)['token'] as String);
```

## Server-sent events and WebSockets

`events(path)` reads a `Response.sse` stream as `SseMessage`s (`event`,
`data`, `id`, `json`). It ends at the server's `</stream>` event:

```dart
await for (final message in api.events('/api/orders/7/status')) {
  print(message.json);
}
```

A WebSocket route becomes a method that returns its URL. Connect with the
client's headers so the route's `auth` middleware sees the token:

```dart
final socket = await WebSocket.connect(
  api.socketRoomsByRoom('lobby').toString(),
  headers: await api.requestHeaders(),
);
```

On Flutter web, browsers can't set WebSocket headers and `package:http`
buffers streamed responses, so use these two on mobile and desktop.

## Not generated yet

Riverpod and Bloc adapters (`--state`) and a `--watch` mode are planned.
Until then, wrap the client in your own providers, and run the command
again after changing routes.
