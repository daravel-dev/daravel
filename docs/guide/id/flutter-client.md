<!-- source: flutter-client.md sha256:13fbb7edec5d -->
# Client Flutter

`dartisan client:flutter` menghasilkan paket client Dart bertipe dari route
Anda. Paketnya Dart biasa di atas `package:http`, jadi bisa dipakai di
aplikasi Flutter (mobile dan desktop) dan di tool command-line Dart. Karena
server dan aplikasinya memakai bahasa yang sama, client dibangun dari tabel
route dan rule validasi milik server sendiri, bukan dari spesifikasi yang
ditulis tangan, dan Anda tidak perlu `build_runner`.

```bash
dart run bin/dartisan.dart client:flutter --output=../mobile/packages/app_client
```

| Opsi | Default | Artinya |
| :-- | :-- | :-- |
| `--output` | `../app_client` | Direktori paket, relatif terhadap aplikasi |
| `--package-name` | `app_client` | Nama paket, sekaligus nama kelas client (`AppClient`) |
| `--prefix` | `/api` | Hanya route di bawah path ini (`/` untuk semua) |
| `--base-url` | `APP_URL` | Base URL default milik client |
| `--locale` | `APP_LOCALE` | Bahasa pesan validasi |
| `--state` | tidak ada | Adapter state: `riverpod`, `bloc`, `cubit` (dipisah koma) |
| `--watch` | | Bangkitkan ulang saat route, request, resource, atau `.env` berubah |

Tambahkan ke aplikasi Flutter dengan path dependency (`app_client: {path:
packages/app_client}`) dan jalankan lagi command-nya setiap kali route
berubah. File yang dihasilkan akan ditimpa. `pubspec.yaml` dan
`analysis_options.yaml` hanya ditulis sekali, jadi Anda bisa menambahkan
isinya.

## Apa berasal dari mana

Command ini mem-boot aplikasi seperti `openapi:generate` dan membaca
metadata setiap route
([Routing](routing.md#validasi-dan-respons-yang-dideklarasikan)). Proyek
baru (`dartisan new`) sudah mendeklarasikannya untuk route auth, jadi
`api.auth.register(...)`, `login(...)`, `me()`, dan `logout()` sudah
bertipe sejak awal:

| Di route | Di client |
| :-- | :-- |
| `.name('users.store')` | `api.users.store(...)`; nama satu segmen seperti `ping` menjadi method di client itu sendiri |
| `{id}` dengan `.whereNumber('id')` | `int id` posisional (parameter lain bertipe `String`) |
| `.validates(FormRequest)` / `.rules({...})` | parameter bernama yang tipenya dari rule, ditambah kelas input dengan rule yang dicek di perangkat |
| `.returns(schema, name: 'User')` | model `User` dengan `fromJson` dan `toJson`; string date-time menjadi `DateTime` |
| `shape: .paginated` / `.simplePaginated` / `.cursorPaginated` | `Page<User>`, `SimplePage<User>`, `CursorPage<User>` dan parameter `page` atau `cursor` |
| `shape: .collection` | `List<User>` |
| `'title': 'User'` di sebuah schema | nama model: schema yang dipakai ulang di respons lain (`user` di respons token) adalah kelas `User` yang sama |
| `.returns(const {}, status: 204)` | `Future<void>` |
| rule `file` | parameter `http.MultipartFile`, dikirim sebagai `multipart/form-data` |
| `router.ws(...)` | method yang mengembalikan URL `ws://` / `wss://` |
| tanpa metadata | `Future<Object?>` dengan map `body` atau `query` |

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

## Error

Body error dari Laravel menjadi exception:

| Status | Exception | Field yang berguna |
| :-- | :-- | :-- |
| 422 | `ValidationException` | `errors` per field, `first('email')` |
| 401 | `UnauthenticatedException` | |
| 429 | `TooManyRequestsException` | `retryAfter` |
| 4xx/5xx lainnya | `ApiException` | `status`, `message`, `body` |

```dart
try {
  await api.users.store(...);
} on ValidationException catch (e) {
  setState(() => emailError = e.first('email'));
}
```

## Validasi di perangkat

Setiap kelas input menyimpan rule server sebagai `static const rules`,
method `validate()` yang mengembalikan pesan per field, dan satu fungsi
`validate<Field>` per field yang cocok untuk `TextFormField.validator`:

```dart
TextFormField(
  decoration: const InputDecoration(labelText: 'Email'),
  validator: UsersStoreInput.validateEmail,
);
```

Pesannya tidak diterjemahkan dua kali. Pesan itu sudah di-resolve oleh
translator server saat client dihasilkan, dengan `attributes()` dan
`messages()` milik form request, jadi bunyinya persis seperti 422 yang akan
dikirim server. Semantik rule-nya juga disalin dari server. Semantik itu
mencakup nilai kosong, `nullable`, `sometimes`, dan `bail`, dan `min`/`max`
memilih pesan string, numerik, atau array berdasarkan tipe nilainya, seperti
di server. Test generator menjalankan keduanya pada input yang sama dan
mengharapkan pesan yang sama.

Rule yang butuh server, seperti `unique`, `exists`, tanggal, file, closure,
dan rule wildcard (`tags.*`), tidak disertakan. Kelas input mencantumkannya
("Checked by the server only"), begitu pula output command-nya. Server
tetap menjadi penentu: client yang lolos tetap bisa mendapat 422 bila,
misalnya, email-nya sudah dipakai.

`confirmed` membandingkan dua field, jadi validator satu field melewatinya
kecuali Anda memberikan nilai lainnya: `validatePassword(value,
{'password_confirmation': confirmController.text})`. `validate()` pada
seluruh input menyertakannya.

## Token

Request mengirim `Authorization: Bearer <token>` bila `TokenStore` milik
client menyimpan token. `MemoryTokenStore` default melupakan token saat
aplikasi di-restart. Implementasikan `TokenStore` di atas
`flutter_secure_storage` untuk menyimpannya:

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
final login = await api.auth.login(email: email, password: password);
await api.tokens.write(login.token);
final me = await api.auth.me(); // dikirim dengan token
```

## Server-sent events dan WebSocket

`events(path)` membaca stream `Response.sse` sebagai `SseMessage` (`event`,
`data`, `id`, `json`). Stream berakhir pada event `</stream>` dari server:

```dart
await for (final message in api.events('/api/orders/7/status')) {
  print(message.json);
}
```

Route WebSocket menjadi method yang mengembalikan URL-nya. Hubungkan dengan
header milik client agar middleware `auth` di route melihat token-nya:

```dart
final socket = await WebSocket.connect(
  api.socketRoomsByRoom('lobby').toString(),
  headers: await api.requestHeaders(),
);
```

Di Flutter web, browser tidak bisa memasang header WebSocket dan
`package:http` mem-buffer respons yang di-stream, jadi pakai keduanya di
mobile dan desktop.

## Manajemen state

`--state` menambahkan adapter di atas client. Adapter memakai paket
`riverpod` dan `bloc` yang Dart murni, yang menjadi dasar `flutter_riverpod`
dan `flutter_bloc`, jadi `ProviderScope`, `BlocProvider`, dan `BlocBuilder`
bekerja dengannya seperti biasa. Command ini menambahkan dependency ke
`pubspec.yaml` paket baru. Untuk paket yang sudah ada, command ini mencetak baris
yang perlu ditambahkan.

```bash
dart run bin/dartisan.dart client:flutter --state=riverpod,cubit
```

**Riverpod** (`providers.dart`). Ada satu provider untuk client dan satu
`FutureProvider.autoDispose` untuk setiap route `GET` yang mengembalikan
data. Route dengan parameter menjadi family. Dengan beberapa parameter,
argumennya berupa record, yang dibandingkan berdasarkan nilai, sehingga
setiap build mendapat request ter-cache yang sama:

```dart
ProviderScope(
  overrides: [
    appClientProvider.overrideWithValue(
      AppClient(baseUrl: 'https://api.example.com', tokens: SecureTokens(storage)),
    ),
  ],
  child: const App(),
);

final user = ref.watch(usersShowProvider(7));          // AsyncValue<User>
final page = ref.watch(usersIndexProvider(2));         // AsyncValue<Page<User>>
ref.invalidate(usersShowProvider);                     // ambil ulang
```

Operasi tulis tidak punya provider. Panggil client dari sebuah handler:
`ref.read(appClientProvider).auth.login(...)`.

**Cubit** (`cubits.dart`) dan **Bloc** (`blocs.dart`). Ada satu per route:
`load(...)` untuk `GET` dan `submit(...)` untuk operasi tulis, atau event
seperti `UsersShowRequested(7)` untuk Bloc. State-nya berupa
`RemoteState<T>`:

| State | Artinya |
| :-- | :-- |
| `RemoteIdle` | belum ada yang diminta |
| `RemoteLoading` | sedang berjalan; `previous` menyimpan data terakhir selama memuat ulang |
| `RemoteData` | `data` |
| `RemoteError` | `error`; `validation` adalah `ValidationException` dari sebuah 422 |

```dart
BlocProvider(
  create: (_) => AuthLoginCubit(api),
  child: BlocBuilder<AuthLoginCubit, RemoteState<AuthToken>>(
    builder: (context, state) => switch (state) {
      RemoteLoading() => const CircularProgressIndicator(),
      RemoteError(:final validation) => Text(validation?.first('email') ?? 'Failed'),
      _ => LoginForm(onSubmit: (email, password) => context
          .read<AuthLoginCubit>()
          .submit(email: email, password: password)),
    },
  ),
);
```

Map `body`/`query` tanpa tipe tidak disertakan di adapter, karena map baru
di setiap build tidak akan pernah dianggap sama. Route yang mendeklarasikan
input-nya mendapat semua field.

## Mode watch

`--watch` membangkitkan ulang paket setiap kali file di bawah `lib`,
`routes`, `bootstrap`, atau `config` berubah, atau `.env` berubah. Tabel
route dikompilasi ke dalam program yang berjalan, jadi setiap run adalah
proses `client:flutter` yang baru. Perubahan yang disimpan selama sebuah run
memulai run berikutnya. Paket yang dihasilkan sendiri diabaikan bila berada
di dalam proyek. Biarkan berjalan di samping `dartisan serve --watch`:

```bash
dart run bin/dartisan.dart client:flutter --output=../mobile/packages/app_client --state=riverpod --watch
```
