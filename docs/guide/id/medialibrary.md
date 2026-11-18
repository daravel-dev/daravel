<!-- source: medialibrary.md sha256:0931d90dc1e5 -->
# Media library

`daravel_medialibrary` melekatkan file ke model, seperti
[spatie/laravel-medialibrary](https://spatie.be/docs/laravel-medialibrary)
v11: satu tabel `media` untuk semua model, collection, dan konversi gambar
(thumbnail dan preview) yang dibuat dari file asli. Baris dan file mengikuti
layout Spatie, sehingga aplikasi Laravel yang memakai database dan disk yang
sama bisa membaca, menyajikan, dan menghapus media yang ditambahkan Daravel,
begitu pula sebaliknya. Gambar dikonversi dengan Dart murni, tanpa GD atau
ImageMagick di container.

```bash
dartisan pub:add media
```

`pub:add` menambahkan dependency, `.withMediaLibrary()`, migration `media`,
dan command `media:*`. Setelah itu:

```bash
dartisan migrate
dartisan storage:link   # menyajikan disk public di /storage
```

## Model

Model yang memiliki media memakai mixin `InteractsWithMedia` dan mendaftarkan
`MediaObserver`, yang menghapus media beserta file-nya bersama model
tersebut. Tambahkan model ke `withModels(...)` agar konversi di queue bisa
memuatnya.

```dart
final class Post extends Model with InteractsWithMedia {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    observers: [MediaObserver<Post>()],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  @override
  void registerMediaCollections() {
    addMediaCollection('cover').singleFile();
    addMediaCollection('attachments')
        .acceptsMimeTypes(['application/pdf', 'image/jpeg', 'image/png']);
  }

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').fit(Fit.crop, 300, 200).nonQueued();
    addMediaConversion('preview').width(1200).performOnCollections(['cover']);
  }
}
```

Model yang memakai soft delete menyimpan media-nya sampai di-force delete.
`post.deletePreservingMedia()` menghapus model dan mempertahankan media-nya.

## Menambahkan file

```dart
router.post('/posts/{post}/cover', (Request request) async {
  final post = (await Post.definition.query().find(request.param<int>('post')))!;
  final media = await post
      .addMedia((await request.file('cover'))!)
      .usingName('Cover')
      .withCustomProperties({'alt': 'Pelabuhan saat fajar'})
      .toMediaCollection('cover');
  return {'url': media.url(), 'thumb': media.url('thumb')};
});
```

`addMediaFromBytes(bytes, fileName: ...)`, `addMediaFromPath(path)`, dan
`addMediaFromDisk(path, disk: ...)` menambahkan file dari sumber lain.
`toMediaCollection(collection, disk)` menyimpan file di disk collection
(`useDisk('s3')`), atau di `MEDIA_DISK` bila collection tidak memilih disk.

File ditolak dengan `FileCannotBeAdded` bila ukurannya melebihi
`MEDIA_MAX_FILE_SIZE` (10 MiB), bila collection-nya tidak menerimanya, atau
bila salah satu bagian namanya adalah ekstensi yang bisa dijalankan web
server (`php`, `phtml`, `phar`, `cgi`, `jsp`, ...; termasuk `shell.php.jpg`).
Nama file dibersihkan seperti Spatie: karakter kontrol dibuang, spasi serta
`#`, `/`, `\` diganti `-`.

## Membaca dan menghapus

```dart
final cover = await post.getFirstMediaUrl('cover', 'thumb');
for (final file in await post.getMedia('attachments')) {
  print('${file.fileName} (${file.humanReadableSize}) ${file.url()}');
}
await post.clearMediaCollection('attachments');
await post.deleteMedia(mediaId);
```

`Media` memiliki `name`, `fileName`, `mimeType`, `size`, `disk`,
`customProperties` (`getCustomProperty('alt')`), `url([conversion])`,
`path([conversion])` relatif terhadap disk, dan `bytes([conversion])`.
`media.toJson()` menambahkan `original_url` dan `preview_url` seperti Spatie.
`getFirstMediaUrl` mengembalikan `useFallbackUrl(...)` collection, atau `''`,
saat collection kosong.

## Konversi

Konversi adalah JPEG yang dibuat dari sebuah gambar, bernama
`<nama file>-<konversi>.jpg` di direktori `conversions` media tersebut,
sesuai penamaan Spatie. Manipulasi dijalankan sesuai urutan pemanggilannya,
masing-masing pada hasil manipulasi sebelumnya, seperti di Spatie:

| Method | Hasil |
| :-- | :-- |
| `width(w)`, `height(h)` | Lebar atau tinggi tersebut, sisi lain mengikuti rasio aspek; jadi `width(200).height(200)` me-resize dua kali |
| `fit(Fit.contain, w, h)` | Di dalam kotak; `Fit.max` tanpa memperbesar; `Fit.fill` dan `Fit.fillMax` lalu mengisi kotak dengan putih (setiap frame animasi) |
| `fit(Fit.crop, w, h)` | Tepat seukuran kotak, dipotong dari tengah |
| `fit(Fit.stretch, w, h)` | Tepat seukuran kotak, rasio aspek diabaikan |
| `crop(w, h, CropPosition.top)` | Potongan di posisi tertentu |
| `quality(85)` | Kualitas JPEG (default 75, seperti GD) |
| `format(ImageFormat.png)`, `keepOriginalImageFormat()` | PNG, GIF, BMP, atau TIFF sebagai ganti JPEG |
| `greyscale()`, `blur(10)` | Filter |

File JPEG, PNG, GIF (termasuk yang beranimasi), WebP, dan BMP bisa
dikonversi, setelah rotasi EXIF-nya diterapkan; formatnya ditentukan dari
isi, bukan dari nama. TIFF serta PNG atau WebP beranimasi tidak dikonversi
di versi ini: file seperti itu tetap menyimpan file aslinya tanpa
konversi. WebP dan AVIF tidak bisa ditulis: `package:image` tidak memiliki
encoder untuk keduanya.

Ukuran gambar dibaca dari header-nya sebelum didekode: gambar yang akan
menjadi lebih dari `MEDIA_MAX_IMAGE_PIXELS` piksel (40 juta, lebar x tinggi x
frame) atau memuat lebih dari `MEDIA_MAX_IMAGE_FRAMES` frame (1 000) tidak
dikonversi (`ImageTooLargeException`), dan file aslinya tetap tersimpan.
File berukuran satu megabyte bisa menyatakan 16 000 x 16 000 piksel, yang
butuh gigabyte untuk didekode. PNG 16-bit dihitung dua kali (dua byte per
sampel), dan JPEG harus memiliki 1 atau 3 komponen warna. Konversi yang
ditolak dengan cara ini langsung menggagalkan job-nya, tanpa diulang.

Setiap gambar yang dibuat oleh `width`, `height`, `fit`, atau `crop` juga
dibatasi seperempat `MEDIA_MAX_IMAGE_PIXELS`, frame ikut dihitung, bahkan
bila lebih kecil dari masukannya. Dimensi harus lebih besar dari nol, tidak
ada gambar yang dibaca atau dibuat boleh punya sisi lebih panjang dari
65 535 piksel, dan JPEG dengan scan lebih banyak dari yang dimungkinkan
ukurannya tidak dikonversi. Manipulasi dijalankan dalam urutan yang
didefinisikan konversi.

Waktu sebuah konversi dibatasi satu anggaran kerja,
`MEDIA_MAX_CONVERSION_WORK` (10 000 unit). Sebelum apa pun didekode,
konversi direncanakan dari header gambar: ukuran, frame, dan format
pikselnya, serta setiap langkah yang akan dijalankan (dekode, memutar ke
posisi tegak, tiap manipulasi, penulisan). Kerja tiap langkah dihitung untuk
setiap frame, dan konversi yang totalnya melewati anggaran tidak dibuat
(`ImageTooLargeException`; berkas asli tetap tersimpan). Satu unit adalah
ukuran kerja relatif: paling lama kira-kira satu milidetik satu inti
runner CI paling lambat yang kami ukur, yaitu runner GitHub Actions
`ubuntu-latest` dengan AMD EPYC 7763 (4 inti, 16 GB, November 2026).
Mesin yang lebih cepat menyelesaikan jumlah unit yang sama lebih cepat, yang
lebih lambat butuh waktu lebih lama: itu bukan janji detik di mesin Anda.
Kombinasi format,
piksel, dan langkah yang belum punya biaya terukur ditolak, bukan ditebak.

Urutan berpengaruh pada anggaran: bila konversi mengubah ukuran dan
melakukan blur, tulis `width` atau `height` sebelum `blur` agar blur bekerja
pada gambar yang lebih kecil. Gambar 16-bit yang dimanipulasi dijadikan
8-bit lebih dulu, seperti GD (driver bawaan laravel-medialibrary); gambar
yang hanya ditulis ke format lain tetap 16-bit. Gambar 1, 2, atau 4-bit
dijadikan 8-bit sebelum greyscale atau blur.

| Konversi | Unit | Runner terlambat yang terukur | Anggaran kerja (bawaan) | Batas piksel (bawaan) |
|---|---|---|---|---|
| JPEG 12 MP (4 000 x 3 000) ke lebar 1 600 | 2 641 | 1,7 dtk | masuk | masuk |
| JPEG 24 MP (6 000 x 4 000) ke lebar 1 600 | 4 311 | 3,0 dtk | masuk | masuk |
| JPEG 40 MP (8 000 x 5 000) ke lebar 1 600 | 6 617 | 3,1 dtk | masuk | masuk |
| JPEG 50 MP (8 160 x 6 120) ke lebar 1 600 | 8 226 | 5,1 dtk | masuk | lewat, kecuali `MEDIA_MAX_IMAGE_PIXELS` dinaikkan |
| PNG 16-bit 24 MP (6 000 x 4 000) ditulis PNG | 11 565 | 6,7 dtk | lewat | lewat, kecuali `MEDIA_MAX_IMAGE_PIXELS` dinaikkan |
| GIF beranimasi 800 x 600, 30 frame, ke lebar 400 sebagai GIF | 907 | 0,3 dtk | masuk | masuk |
| PNG kecil diperbesar ke 10 juta piksel, crop, fill, blur 30, ditulis GIF | 16 132 | 12,0 dtk | lewat | masuk |

Kedua batas berlaku, dan menaikkan satu tidak menghapus yang lain: foto
50 MP butuh `MEDIA_MAX_IMAGE_PIXELS` dinaikkan, lalu resize-nya ke lebar 1 600 muat dalam
anggaran (8 226 unit); PNG 16-bit 30 MP juga butuh batas itu dinaikkan, dan
sesudahnya tetap ditolak anggaran (14 456 unit) sampai
`MEDIA_MAX_CONVERSION_WORK` juga dinaikkan. Naikkan anggaran untuk
mengonversi gambar yang lebih besar atau rantai yang lebih panjang, dan
beri job konversi timeout di atas waktu sejumlah unit itu di mesin Anda.

Batas-batas ini menjaga memori tetap terbatas, meski tidak kecil.
Mengonversi gambar pada batas bawaan memakan (puncak terukur):

| Gambar | Memori |
|---|---|
| JPEG baseline, 8 000 x 5 000 | sekitar 130 MiB |
| JPEG progresif, 8 000 x 5 000 (dengan atau tanpa orientasi) | sekitar 415 MiB |
| PNG, 6 324 x 6 324 | sekitar 205 MiB |
| PNG 16-bit, 4 472 x 4 472 | sekitar 205 MiB |
| WebP, 4 472 x 4 472 | sekitar 170 sampai 175 MiB; sampai sekitar 470 MiB pada kasus terburuk, dengan orientasi |
| GIF, 1 000 frame 200 x 200 | sekitar 140 MiB |
| JPEG pada batas scan-nya (40, 20, atau 5 MP) | sampai sekitar 430 MiB |
| manipulasi yang membuat 10 juta piksel | sekitar 47 sampai 76 MiB |
| satu konversi utuh pada batas | sampai sekitar 384 MiB |

WebP dan PNG 16-bit dihitung terhadap setengah `MEDIA_MAX_IMAGE_PIXELS`.
Batas ini membatasi ukuran gambar, bukan memori secara persis: pada batas
bawaan, siapkan sekitar 500 MiB memori per konversi yang berjalan
bersamaan, berapa pun ukuran gambarnya, dan turunkan
`MEDIA_MAX_IMAGE_PIXELS` bila konversi berbagi proses dengan request.

Anggaran berlaku per konversi: tidak ada yang membatasi jumlah konversi
yang berjalan bersamaan selain cara menjalankannya. Konversi berjalan di
queue (`PerformConversionsJob`, di `MEDIA_QUEUE`) kecuali menyatakan
`nonQueued()` atau `QUEUE_CONVERSIONS_BY_DEFAULT=false`; di queue `sync`
konversi langsung berjalan. Di queue, paling banyak sebanyak worker queue
itu yang berjalan bersamaan; konversi `nonQueued()` berjalan di request yang
menambahkan berkas, sebanyak request yang sedang berjalan. Jalankan konversi
di queue, dengan jumlah worker terbatas dan timeout job di atas waktu
anggaran, bukan di dalam request. Pekerjaan gambarnya sendiri berjalan di
isolate terpisah, jadi foto besar tidak menahan request di sebelahnya.

## Command

| Command | Fungsinya |
| :-- | :-- |
| `media:regenerate [modelType] [--ids=1,2] [--only=thumb] [--only-missing]` | Membuat ulang konversi setelah definisinya berubah |
| `media:clean [--disk] [--dry-run] [--force]` | Menghapus konversi yang tidak lagi didefinisikan model dan direktori media tanpa baris |

## Pengaturan

| Variabel | Default | |
| :-- | :-- | :-- |
| `MEDIA_DISK` | `public` | Disk untuk collection yang tidak memilih disk |
| `MEDIA_MAX_FILE_SIZE` | `10485760` | Ukuran file terbesar, dalam byte |
| `MEDIA_MAX_IMAGE_PIXELS` | `40000000` | Jumlah piksel terbanyak hasil dekode gambar untuk konversinya |
| `MEDIA_MAX_IMAGE_FRAMES` | `1000` | Jumlah frame terbanyak sebuah gambar untuk konversinya |
| `MEDIA_MAX_CONVERSION_WORK` | `10000` | Kerja terbanyak sebuah konversi, dalam unit kira-kira satu milidetik satu inti runner acuan |
| `MEDIA_QUEUE` | queue default | Queue untuk job konversi |
| `QUEUE_CONVERSIONS_BY_DEFAULT` | `true` | Konversi tanpa `nonQueued()` dijalankan di queue |
| `MEDIA_PREFIX` | tidak ada | Direktori di depan setiap direktori media |
| `MEDIA_VERSION_URLS` | `false` | Menambahkan `?v=<updated_at>` ke URL |

## Media Laravel

`bench/interop/medialibrary.sh` menjalankan Laravel 12 dengan
spatie/laravel-medialibrary 11.23 dan Daravel di satu database SQLite dan
satu disk public. Migration Spatie membuat tabelnya; masing-masing membaca
baris, custom property, dan konversi (ukuran sama) dari sisi lain,
menyajikannya di URL yang sama, dan menghapusnya beserta file-nya.
`model_type` sebuah model adalah morph class-nya (`App\Models\Post` secara
default, atau alias `Relation.morphMap()`), sama seperti yang disimpan
Laravel.

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `php artisan media-library:regenerate` | `dartisan media:regenerate` | `MediaRegenerateCommand` |  |
| `php artisan media-library:clean` | `dartisan media:clean` | `MediaCleanCommand` |  |
