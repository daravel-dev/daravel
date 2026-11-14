import 'package:daravel/daravel.dart';

/// `config/media-library.php` (spatie/laravel-medialibrary v11), with its
/// environment variables.
final class MediaLibraryConfig implements ConfigSection {
  /// Media library settings; usually from `.env` (`MEDIA_*`).
  const MediaLibraryConfig({
    this.diskName = 'public',
    this.maxFileSize = 10 * 1024 * 1024,
    this.queueName,
    this.queueConversionsByDefault = true,
    this.prefix = '',
    this.versionUrls = false,
    this.disallowedExtensions = defaultDisallowedExtensions,
    this.maxImagePixels = defaultMaxImagePixels,
    this.maxImageFrames = defaultMaxImageFrames,
  });

  /// The settings in `MEDIA_*`.
  ///
  /// `MEDIA_MAX_IMAGE_PIXELS` or `MEDIA_MAX_IMAGE_FRAMES` below 1 stops the
  /// boot with a [ConfigException] instead of refusing every image; one
  /// that is not a number does already ([EnvException]).
  factory MediaLibraryConfig.fromEnv(Env env) {
    final queue = env.maybeString('MEDIA_QUEUE');
    for (final key in ['MEDIA_MAX_IMAGE_PIXELS', 'MEDIA_MAX_IMAGE_FRAMES']) {
      final value = env.integer(key, 1);
      if (value < 1) {
        throw ConfigException('$key is at least 1, not $value.');
      }
    }
    return MediaLibraryConfig(
      diskName: env.string('MEDIA_DISK', 'public'),
      maxFileSize: env.integer('MEDIA_MAX_FILE_SIZE', 10 * 1024 * 1024),
      queueName: queue == null || queue.isEmpty ? null : queue,
      queueConversionsByDefault: env.boolean(
        'QUEUE_CONVERSIONS_BY_DEFAULT',
        true,
      ),
      prefix: env.string('MEDIA_PREFIX', ''),
      versionUrls: env.boolean('MEDIA_VERSION_URLS', false),
      maxImagePixels: env.integer(
        'MEDIA_MAX_IMAGE_PIXELS',
        defaultMaxImagePixels,
      ),
      maxImageFrames: env.integer(
        'MEDIA_MAX_IMAGE_FRAMES',
        defaultMaxImageFrames,
      ),
    );
  }

  /// Spatie's `FileAdder::$defaultDisallowedExtensions`: refused in any
  /// segment of a file name, so `shell.php.jpg` is refused too.
  static const List<String> defaultDisallowedExtensions = [
    'php', 'php3', 'php4', 'php5', 'php6', 'php7', 'php8', //
    'phtml', 'phtm', 'pht', 'phps', 'phar', //
    'shtml', 'shtm', 'stm', //
    'htaccess', 'htpasswd', //
    'cgi', 'pl', 'asp', 'aspx', 'jsp', 'jspx',
  ];

  /// [maxImagePixels] by default: 40 million, a 7 300 x 5 500 photo (a
  /// 24 MP camera fits with room). Converting an image at the limit takes
  /// memory and time (measured in a compiled process, peak resident
  /// memory): a baseline JPEG of 8 000 x 5 000 about 130 MiB and 2.5 s, a
  /// progressive one about 415 MiB and 3 s, a PNG about 205 MiB and 1 s, a
  /// WebP (which counts against half of it, as a 16-bit PNG does) up to
  /// about 470 MiB, an animated GIF filling the budget about 140 MiB and
  /// 1.2 s; plan about 500 MiB per conversion running at once, whatever the
  /// size of the image. Lower it
  /// where conversions share a process with requests.
  static const int defaultMaxImagePixels = 40000000;

  /// [maxImageFrames] by default.
  static const int defaultMaxImageFrames = 1000;

  /// The most pixels an image may decode to before its conversions run
  /// (`MEDIA_MAX_IMAGE_PIXELS`): width x height x frames, read from the
  /// file's header before anything is decoded. A larger image is not
  /// converted (`ImageTooLargeException`); the original stays stored. A
  /// small PNG can declare 16 000 x 16 000 pixels, 1 GiB once decoded.
  final int maxImagePixels;

  /// The most frames an image may hold before its conversions run
  /// (`MEDIA_MAX_IMAGE_FRAMES`, 1 000), read from the header as well.
  final int maxImageFrames;

  /// The disk of files that choose none (`MEDIA_DISK`, `public`).
  final String diskName;

  /// The largest file accepted, in bytes (`MEDIA_MAX_FILE_SIZE`, 10 MiB as
  /// Spatie's `max_file_size`).
  final int maxFileSize;

  /// The queue of conversion jobs (`MEDIA_QUEUE`); the default queue when
  /// null.
  final String? queueName;

  /// Whether conversions run on the queue unless one says `nonQueued()`
  /// (`QUEUE_CONVERSIONS_BY_DEFAULT`, true).
  final bool queueConversionsByDefault;

  /// A directory in front of every media directory (`MEDIA_PREFIX`).
  final String prefix;

  /// Appends `?v=<updated_at>` to URLs (`MEDIA_VERSION_URLS`, Spatie's
  /// `version_urls`).
  final bool versionUrls;

  /// Extensions refused whatever the collection accepts.
  final List<String> disallowedExtensions;

  @override
  String get key => 'media_library';

  @override
  Map<String, Object?> toMap() => {
    'disk_name': diskName,
    'max_file_size': maxFileSize,
    'queue_name': queueName ?? '',
    'queue_conversions_by_default': queueConversionsByDefault,
    'prefix': prefix,
    'version_urls': versionUrls,
    'disallowed_extensions': disallowedExtensions,
    'max_image_pixels': maxImagePixels,
    'max_image_frames': maxImageFrames,
  };
}
