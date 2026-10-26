<!-- source: validation.md sha256:01e03da96d6a -->
# Validasi

Validasi request secara inline dengan string rule Laravel, atau dengan objek
rule bertipe dari `Rules`:

```dart
final data = await request.validate({
  'email': 'required|email|unique:users',
  'password': 'required|min:8|confirmed',
  'role': [Rules.required(), Rules.inList(['admin', 'editor'])],
  'tags.*': 'string|max:20',
});
data.string('email'); // akses bertipe, hanya ke input yang sudah divalidasi
```

Objek rule juga bisa dirangkai, sehingga compiler mengecek nama dan
argumennya:

```dart
.rules({
  'email': Rules.required().string().email().max(255).unique('users'),
  'age': Rules.nullable().integer().min(18),
  'avatar': Rules.nullable().image().max(2048),
})
```

Setiap `Rules.x()` memulai rangkaian, setiap langkah menambahkan rule dengan
nama yang sama, dan rangkaian memvalidasi, melaporkan, serta
mendokumentasikan (OpenAPI) persis seperti string padanannya. String, objek
rule, dan rangkaian bisa dicampur bebas dalam satu list.

String rule di-parse saat route atau request didefinisikan, jadi salah ketik
gagal saat boot atau di test pertama; `dartisan lint`
(`invalid_validation_rule`) melaporkannya lebih awal beserta barisnya,
termasuk argumen yang hilang seperti `max` tanpa nilai.

Kegagalan melempar `ValidationException`, yang dirender sebagai body 422
milik Laravel:

```json
{
  "message": "The email field is required. (and 1 more error)",
  "errors": {
    "email": ["The email field is required."],
    "password": ["The password field must be at least 8 characters."]
  }
}
```

Pesan bahasa Inggris bawaan identik dengan `lang/en/validation.php` Laravel 12
(dicek suite konformansi terhadap file aslinya). Bahasa Indonesia tersedia
sebagai locale kedua: set `request.attributes['locale'] = 'id'` (misalnya di
sebuah middleware).

## Semantik yang dikunci ke Laravel

- `nullable` menghentikan rule berikutnya bila nilainya `null`.
- Field yang tidak ada dan tidak `required` melewati rule non-implisit;
  `sometimes` hanya memvalidasi bila key-nya ada.
- `confirmed` mencari `{field}_confirmation`.
- `bail` berhenti pada kegagalan pertama sebuah field.
- Data bersarang memakai path bertitik dan wildcard `*`.

## Form request

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

`await FormRequest.run(const StorePostRequest(), request)` menjalankan
`authorize()` (403 bila mengembalikan `false`), lalu rule-nya, dan
mengembalikan data yang sudah divalidasi.
`dart run bin/dartisan.dart make:request StorePostRequest` membuatnya.

Sebagai gantinya, deklarasikan di route dengan
`.validates(const StorePostRequest())` lalu baca `request.validated()` di
handler; lihat [Routing](routing.md#validasi-dan-respons-yang-dideklarasikan).

## Upload file

Body `multipart/form-data` di-parse saat datang: field menjadi input seperti
form, dan setiap file dialirkan ke file sementara (dihapus setelah respons)
dan muncul sebagai `UploadedFile`. Nama seperti `photos[]` dan
`user[avatar]` bersarang seperti di Laravel.

```dart
router.post('/avatar', (request) async {
  final data = request.validated();
  final path = await data.file('avatar').store('avatars', disk: 'public');
  return {'url': Storage.disk('public').url(path)};
}).rules(const {'avatar': 'required|image|max:2048'});
```

- `request.file('avatar')`, `request.hasFile('photos')`, dan
  `request.uploadedFiles()` membaca upload; `all()` ikut menyertakannya.
- `UploadedFile`: `clientName`, `clientExtension`, `clientMimeType` (dikirim
  client, tidak dipercaya), `mimeType` dan `extension` (dideteksi dari
  isinya), `size`, `bytes()`, `text()`, `openRead()`, `hashName()`,
  `store(directory, disk:)`, dan `storeAs(directory, name, disk:)`.
- Rule, seperti di Laravel 12: `file`, `image` (jpg, jpeg, png, gif, bmp,
  webp; `image:allow_svg` menambahkan SVG), `mimes:pdf,docx` (ekstensi dari
  tipe yang terdeteksi), `mimetypes:image/*`, `extensions:csv,txt` (nama file
  dari client), serta `min`, `max`, `size`, `between` dalam kilobyte. File
  PHP ditolak kecuali `php` dicantumkan.
- Tipe dideteksi dari isinya (PDF, gambar, file Office dan OpenDocument,
  arsip, teks), tidak pernah dari nama file: file teks bernama `photo.png`
  bukan gambar.
- Batas ukuran body dari `BodyLimitsMiddleware` (default 50 MiB) mencakup
  upload; sebuah request juga menerima paling banyak 1 000 field dan 20 file.

Di test, kirim file dengan `client.post(uri, files: {...})` (atau
`Request.fake(files: ...)`) dan buat file-nya dengan `UploadedFile.fake`:

```dart
await client.post('/api/avatar', files: {
  'avatar': UploadedFile.fake.image('me.png', kilobytes: 120),
  'photos': [UploadedFile.fake.image('1.png'), UploadedFile.fake.image('2.gif')],
});
```
