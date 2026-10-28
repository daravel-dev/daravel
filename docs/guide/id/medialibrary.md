<!-- source: medialibrary.md sha256:d9b957372689 -->
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

File JPEG, PNG, GIF, WebP, BMP, dan TIFF bisa dikonversi, setelah rotasi
EXIF-nya diterapkan. WebP dan AVIF tidak bisa ditulis: `package:image` tidak
memiliki encoder untuk keduanya.

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
