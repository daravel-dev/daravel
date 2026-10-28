# Media library

`daravel_medialibrary` attaches files to models, the way
[spatie/laravel-medialibrary](https://spatie.be/docs/laravel-medialibrary)
v11 does: one `media` table for every model, collections, and image
conversions (thumbnails and previews) made from the original. Rows and files
follow Spatie's layout, so a Laravel application on the same database and
disk reads, serves and deletes the media Daravel adds, and the other way
round. Images are converted in pure Dart, without GD or ImageMagick in the
container.

```bash
dartisan pub:add media
```

`pub:add` adds the dependency, `.withMediaLibrary()`, the `media` migration
and the `media:*` commands. Then:

```bash
dartisan migrate
dartisan storage:link   # serves the public disk at /storage
```

## Models

A model with media mixes in `InteractsWithMedia` and lists a
`MediaObserver`, which deletes its media and their files with it. Add the
model to `withModels(...)` so queued conversions can load it.

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

A model that soft deletes keeps its media until it is force deleted.
`post.deletePreservingMedia()` deletes the model and keeps them.

## Adding files

```dart
router.post('/posts/{post}/cover', (Request request) async {
  final post = (await Post.definition.query().find(request.param<int>('post')))!;
  final media = await post
      .addMedia((await request.file('cover'))!)
      .usingName('Cover')
      .withCustomProperties({'alt': 'The harbour at dawn'})
      .toMediaCollection('cover');
  return {'url': media.url(), 'thumb': media.url('thumb')};
});
```

`addMediaFromBytes(bytes, fileName: ...)`, `addMediaFromPath(path)` and
`addMediaFromDisk(path, disk: ...)` add files from elsewhere.
`toMediaCollection(collection, disk)` stores the file on the collection's
disk (`useDisk('s3')`), else on `MEDIA_DISK`.

A file is refused with `FileCannotBeAdded` when it is larger than
`MEDIA_MAX_FILE_SIZE` (10 MiB), when its collection does not accept it, or
when any part of its name is an extension a web server may run (`php`,
`phtml`, `phar`, `cgi`, `jsp`, ...; `shell.php.jpg` included). File names
are cleaned as Spatie cleans them: control characters removed, spaces and
`#`, `/`, `\` turned into `-`.

## Reading and deleting

```dart
final cover = await post.getFirstMediaUrl('cover', 'thumb');
for (final file in await post.getMedia('attachments')) {
  print('${file.fileName} (${file.humanReadableSize}) ${file.url()}');
}
await post.clearMediaCollection('attachments');
await post.deleteMedia(mediaId);
```

`Media` has the file's `name`, `fileName`, `mimeType`, `size`, `disk`,
`customProperties` (`getCustomProperty('alt')`), `url([conversion])`,
`path([conversion])` relative to the disk and `bytes([conversion])`.
`media.toJson()` adds `original_url` and `preview_url` as Spatie does.
`getFirstMediaUrl` returns the collection's `useFallbackUrl(...)`, or `''`,
when the collection is empty.

## Conversions

A conversion is a JPEG made from an image, named
`<file name>-<conversion>.jpg` in the media's `conversions` directory, as
Spatie names it. Manipulations run in the order they are set, each on the
result of the one before, as in Spatie:

| Method | Result |
| :-- | :-- |
| `width(w)`, `height(h)` | That width or height, the other side following the aspect ratio; `width(200).height(200)` therefore resizes twice |
| `fit(Fit.contain, w, h)` | Within the box; `Fit.max` without upsizing; `Fit.fill` and `Fit.fillMax` then pad to the box in white |
| `fit(Fit.crop, w, h)` | Exactly the box, cut from the middle |
| `fit(Fit.stretch, w, h)` | Exactly the box, aspect ratio ignored |
| `crop(w, h, CropPosition.top)` | A cut-out at a position |
| `quality(85)` | JPEG quality (75 by default, as GD) |
| `format(ImageFormat.png)`, `keepOriginalImageFormat()` | PNG, GIF, BMP or TIFF instead of JPEG |
| `greyscale()`, `blur(10)` | Filters |

JPEG, PNG, GIF, WebP, BMP and TIFF files are converted, after their EXIF
rotation is applied. WebP and AVIF cannot be written: `package:image` has
no encoder for them.

Conversions run on the queue (`PerformConversionsJob`, on `MEDIA_QUEUE`)
unless they say `nonQueued()` or `QUEUE_CONVERSIONS_BY_DEFAULT=false`; on
the `sync` queue they run at once. The image work itself runs in a separate
isolate, so a large photo does not hold up the requests beside it.

## Commands

| Command | What it does |
| :-- | :-- |
| `media:regenerate [modelType] [--ids=1,2] [--only=thumb] [--only-missing]` | Generates the conversions again, after their definitions changed |
| `media:clean [--disk] [--dry-run] [--force]` | Deletes conversions no model defines any more and media directories without a row |

## Settings

| Variable | Default | |
| :-- | :-- | :-- |
| `MEDIA_DISK` | `public` | The disk of collections that choose none |
| `MEDIA_MAX_FILE_SIZE` | `10485760` | The largest file, in bytes |
| `MEDIA_QUEUE` | the default queue | The queue of conversion jobs |
| `QUEUE_CONVERSIONS_BY_DEFAULT` | `true` | Queue conversions that do not say `nonQueued()` |
| `MEDIA_PREFIX` | none | A directory in front of every media directory |
| `MEDIA_VERSION_URLS` | `false` | Appends `?v=<updated_at>` to URLs |

## Laravel media

`bench/interop/medialibrary.sh` runs Laravel 12 with
spatie/laravel-medialibrary 11.23 and Daravel on one SQLite database and
one public disk. Spatie's migration creates the table; each reads the
other's rows, custom properties and conversions (same sizes), serves them
at the same URLs, and deletes them with their files. A model's
`model_type` is its morph class (`App\Models\Post` by default, or the
`Relation.morphMap()` alias), as Laravel stores it.
