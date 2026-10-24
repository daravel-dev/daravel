<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel

A Laravel-inspired, AOT-native backend framework for Dart. Routing,
middleware, validation with Laravel's rules and messages, a query builder and
an Eloquent-style ORM, migrations, Sanctum-compatible tokens, JWT, gates,
cache, queues, events, a scheduler, API resources, storage and structured
logging, served by one native executable that scales across isolates.

Laravel and Daravel can share a database: error and pagination JSON, Sanctum
tokens, bcrypt hashes, `Crypt` payloads and the framework tables use
Laravel's formats, locked by a conformance suite.

## Get started

The fastest way is the CLI, which creates a complete project:

```bash
dart pub global activate dartisan_cli
dartisan new blog
cd blog
dart run bin/dartisan.dart migrate --seed
dart run bin/dartisan.dart serve --watch
```

Or add the framework to an existing package:

```bash
dart pub add daravel
```

```dart
import 'package:daravel/daravel.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRouting(
      apiPrefix: '/api',
      api: (router) {
        router.get('/ping', (_) => {'message': 'pong'});
        router.post('/users', (request) async {
          final data = await request.validate({
            'email': 'required|email|unique:users',
            'password': 'required|min:8|confirmed',
          });
          return Response.created(data.toMap());
        });
      },
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
```

See [`example/main.dart`](example/main.dart) and the
[documentation](https://github.com/daravel-dev/daravel/blob/main/docs/guide/index.md),
including the [Laravel ⇄ Daravel parity table](https://github.com/daravel-dev/daravel/blob/main/docs/guide/parity.md).

## Related packages

- [`dartisan_cli`](https://pub.dev/packages/dartisan_cli): project creation, dev server with hot reload, generators, migrations, native builds.
- [`daravel_test`](https://pub.dev/packages/daravel_test): `TestClient`, assertions, database helpers, fakes and Laravel conformance matchers.
- [`daravel_lints`](https://pub.dev/packages/daravel_lints): AST lint rules for Daravel applications.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" and "Flutter"
are trademarks of Google LLC. Daravel is an independent project, not
affiliated with or endorsed by either.
