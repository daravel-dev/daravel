<!-- source: localization.md sha256:27eedbf52666 -->
# Lokalisasi

Terjemahan bekerja seperti di Laravel: baris ber-key dengan locale fallback,
baris JSON yang key-nya adalah teks itu sendiri, placeholder `:name`, dan
baris plural, dengan locale aktif disimpan per request, sehingga request
yang berjalan bersamaan dalam bahasa berbeda tidak pernah saling melihat.

## Baris

Baris ber-key (`lang/<locale>/*.php` milik Laravel) didaftarkan di
`bootstrap/app.dart`; map bersarang menjadi key bertitik:

```dart
Application.configure(basePath: '.')
    .withTranslations({
      'en': {
        'auth': {'failed': 'These credentials do not match our records.'},
        'exam.welcome': 'Welcome, :name!',
        'exam.minutes': '{1} :count minute left|[2,*] :count minutes left',
      },
      'id': {
        'auth.failed': 'Kredensial ini tidak cocok dengan data kami.',
        'exam.welcome': 'Selamat datang, :name!',
        'exam.minutes': ':count menit tersisa',
      },
    })
```

Baris JSON dibaca dari `lang/<locale>.json` saat boot, file yang sama dengan
yang dipakai aplikasi Laravel, jadi keduanya bisa berbagi:

```json
{"Log in": "Masuk", "Forgot your password?": "Lupa kata sandi?"}
```

Sertakan direktori `lang/` di samping biner, seperti `.env`.

## Menerjemahkan

```dart
trans('exam.welcome', {'name': 'teo'});        // Welcome, teo!
trans('Log in');                               // Masuk (locale id)
transChoice('exam.minutes', 5);                // 5 minutes left
Lang.get('auth.failed', const {}, 'id');       // locale tertentu
Lang.has('exam.welcome');
```

`trans` adalah `__()` dan `trans()` milik Laravel: Dart memakai garis bawah
di depan untuk nama privat, jadi tidak ada `__`. Key yang tidak ada
mengembalikan key itu sendiri. `:name` memakai nilai apa adanya, `:Name`
mengapitalkan huruf pertamanya, dan `:NAME` menjadikannya huruf besar semua;
placeholder terpanjang yang menang dan teks pengganti tidak dipindai lagi,
seperti `strtr` di PHP.

`transChoice` (`trans_choice` milik Laravel) mengisi `:count` dan memilih
bentuknya: segmen eksplisit `{n}` atau `[from,to]` (`*` untuk ujung terbuka)
yang cocok, atau bentuk plural milik locale. Aturan plural-nya sama dengan
Laravel, untuk 280 locale, jadi `apple|apples` menjadi `apples` untuk 0 dalam
bahasa Inggris, dan bahasa Indonesia, yang hanya punya satu bentuk, selalu
memakai bentuk pertama.

Baris ber-key jatuh ke `APP_FALLBACK_LOCALE` (default `en`); baris JSON
tidak, seperti di Laravel.

## Locale saat ini

`APP_LOCALE` adalah locale aplikasi. `App.setLocale('id')` mengubahnya untuk
sisa request, job, atau command yang sedang berjalan, dan `App.locale`
membacanya. `SetLocaleMiddleware` memilihnya dari `?lang=` atau header
`Accept-Language` di antara locale yang Anda dukung:

```dart
.withMiddleware((middleware) {
  middleware.use(const [SetLocaleMiddleware(supported: ['en', 'id'])]);
})
```

Pesan validasi mengikuti locale saat ini (bahasa Inggris dan Indonesia sudah
disertakan).
