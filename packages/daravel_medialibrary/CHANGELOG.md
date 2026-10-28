# Changelog

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- First release: `InteractsWithMedia` and `MediaObserver` (spatie/laravel-medialibrary v11's trait), `addMedia` / `addMediaFromBytes` / `addMediaFromPath` / `addMediaFromDisk` with `FileAdder` (`usingName`, `usingFileName`, `withCustomProperties`, `setOrder`, `toMediaCollection`), `MediaCollection` (`singleFile`, `onlyKeepLatest`, `acceptsFile`, `acceptsMimeTypes`, `useDisk`, `storeConversionsOnDisk`, fallback URLs and paths), the `Media` model on Spatie's `media` table and file layout (`uuid`, `order_column`, custom properties, `generated_conversions`, `url`, `path`, `humanReadableSize`), `CreateMediaTable`, conversions in pure Dart (`width`, `height`, `fit` with Spatie's `Fit` modes, `crop`, `quality`, `format`, `greyscale`, `blur`, `keepOriginalImageFormat`, EXIF rotation; JPEG by default) in a separate isolate, `PerformConversionsJob` for queued ones, Spatie's file name sanitizer and disallowed extensions, `MEDIA_*` settings, and `media:regenerate` / `media:clean`.
