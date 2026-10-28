<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_medialibrary

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_medialibrary/README.id.md)

Files and images attached to [Daravel](https://pub.dev/packages/daravel)
models, the way spatie/laravel-medialibrary v11 does it: one `media` table,
collections, and image conversions made from the original. Rows and files
follow Spatie's layout, so a Laravel application on the same database and
disk shares them. Images are converted in pure Dart, with no GD or
ImageMagick to install.

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

- Spatie's `media` table, `<id>/<file>` and
  `<id>/conversions/<file>-<conversion>.jpg`: Laravel and Daravel read,
  serve and delete each other's media.
- Conversions with Spatie's resize rules (`width`, `height`, `fit`, `crop`)
  in a separate isolate, JPEG by default, EXIF rotation applied; queued
  ones run as a job.
- Single-file collections, accepted MIME types, size limit, and Spatie's
  file name cleaning and refused extensions (`shell.php.jpg`).
- `media:regenerate` and `media:clean`.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/medialibrary.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
