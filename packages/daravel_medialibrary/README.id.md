<!-- source: README.md sha256:42d7365b262f -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_medialibrary

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_medialibrary/README.md) · Bahasa Indonesia

File dan gambar yang dilekatkan ke model [Daravel](https://pub.dev/packages/daravel),
seperti spatie/laravel-medialibrary v11: satu tabel `media`, collection, dan
konversi gambar yang dibuat dari file asli. Baris dan file mengikuti layout
Spatie, sehingga aplikasi Laravel yang memakai database dan disk yang sama
bisa berbagi media tersebut. Gambar dikonversi dengan Dart murni, tanpa GD
atau ImageMagick yang perlu dipasang.

```bash
dartisan pub:add media
```

```dart
import 'package:daravel_medialibrary/daravel_medialibrary.dart';

final class Post extends Model with InteractsWithMedia {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    observers: [MediaObserver<Post>()],
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  @override
  void registerMediaCollections() => addMediaCollection('cover').singleFile();

  @override
  void registerMediaConversions([Media? media]) {
    addMediaConversion('thumb').fit(Fit.crop, 300, 200).nonQueued();
  }
}

final media = await post
    .addMedia((await request.file('cover'))!)
    .toMediaCollection('cover');
final thumb = await post.getFirstMediaUrl('cover', 'thumb');
```

- Tabel `media` Spatie, `<id>/<file>` dan
  `<id>/conversions/<file>-<konversi>.jpg`: Laravel dan Daravel saling
  membaca, menyajikan, dan menghapus media satu sama lain.
- Konversi dengan aturan resize Spatie (`width`, `height`, `fit`, `crop`)
  di isolate terpisah, JPEG secara default, rotasi EXIF diterapkan;
  konversi di queue berjalan sebagai job.
- Collection satu file, MIME type yang diterima, batas ukuran, serta
  pembersihan nama file dan ekstensi terlarang seperti Spatie
  (`shell.php.jpg`).
- `media:regenerate` dan `media:clean`.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/medialibrary.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak berafiliasi
dengan atau didukung oleh keduanya.
