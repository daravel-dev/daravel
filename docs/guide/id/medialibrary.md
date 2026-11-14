<!-- source: medialibrary.md sha256:cfc31537dccf -->
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
| `fit(Fit.contain, w, h)` | Di dalam kotak; `Fit.max` tanpa memperbesar; `Fit.fill` dan `Fit.fillMax` lalu mengisi kotak dengan putih |
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

Batas ini menjaga memori tetap terbatas, tetapi tidak kecil. Mengonversi
gambar tepat di batas bawaan memakan (puncak terukur):

| Gambar | Memori | Waktu |
|---|---|---|
| JPEG baseline, 8 000 x 5 000 | sekitar 130 MiB | 2,5 dtk |
| sama, orientasi EXIF 6 | sekitar 130 MiB | 3,5 dtk |
| JPEG progresif, 8 000 x 5 000 (dengan atau tanpa orientasi) | sekitar 415 MiB | 3 dtk |
| PNG, 6 324 x 6 324 | sekitar 205 MiB | 1 dtk |
| PNG 16-bit, 4 472 x 4 472 | sekitar 205 MiB | 1 dtk |
| WebP, 4 472 x 4 472 | sekitar 170 sampai 175 MiB | 0,3 sampai 0,9 dtk |
| sama, orientasi EXIF 6 | sekitar 245 MiB | 0,8 dtk |
| WebP ukuran berapa pun, juga yang kecil | sampai sekitar 240 MiB | di bawah 1 dtk |
| GIF, 1 000 frame 200 x 200 | sekitar 140 MiB | 1,2 dtk |

WebP dan PNG 16-bit dihitung terhadap separuh `MEDIA_MAX_IMAGE_PIXELS`.
Batas ini membatasi ukuran gambar, bukan memori secara persis: pada batas
bawaan, siapkan sekitar 450 MiB memori untuk setiap konversi yang berjalan
bersamaan, dan turunkan `MEDIA_MAX_IMAGE_PIXELS` bila konversi berbagi
proses dengan request.

Konversi berjalan di queue (`PerformConversionsJob`, di `MEDIA_QUEUE`),
kecuali konversi menyatakan `nonQueued()` atau
`QUEUE_CONVERSIONS_BY_DEFAULT=false`; di queue `sync` konversi langsung
berjalan. Pemrosesan gambar sendiri berjalan di isolate terpisah, sehingga
foto besar tidak menahan request lain.

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
