### Fixed

- Security: `daravel_medialibrary` decoded an image for its conversions whatever size its header declared: a 995 368-byte PNG of 16 000 x 16 000 RGBA pixels took 2.2 GiB of memory (an isolate shares its process's memory), and GIF, BMP and WebP files did the same. The size is now read from the header before anything is decoded; an image past `MEDIA_MAX_IMAGE_PIXELS` (40 million pixels, width x height x frames) or `MEDIA_MAX_IMAGE_FRAMES` (1 000) throws `ImageTooLargeException` and is not converted; the original stays stored (the same file now peaks at 16 MiB). The EXIF orientation is baked only when there is one to apply, instead of copying every image. Since 1.0.0.

### Upgrade notes

- Upgrading can leave the conversions of an image larger than 40 million pixels (width x height x frames) or with more than 1 000 frames ungenerated, with an `ImageTooLargeException` in the failed conversion job; raise `MEDIA_MAX_IMAGE_PIXELS` / `MEDIA_MAX_IMAGE_FRAMES` if such images are expected. `ImageConversionException` is now a `base` class. New public names: `ImageTooLargeException`, `MediaLibraryConfig.maxImagePixels`, `MediaLibraryConfig.maxImageFrames`, `MediaLibraryConfig.defaultMaxImagePixels`, `MediaLibraryConfig.defaultMaxImageFrames`, and the `maxPixels`/`maxFrames` parameters of `convertImage`/`convertImageSync`.
