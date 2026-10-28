import 'package:daravel/daravel.dart';

/// `config/media-library.php` (spatie/laravel-medialibrary v11), with its
/// environment variables.
final class MediaLibraryConfig implements ConfigSection {
  const MediaLibraryConfig({
    this.diskName = 'public',
    this.maxFileSize = 10 * 1024 * 1024,
    this.queueName,
    this.queueConversionsByDefault = true,
    this.prefix = '',
    this.versionUrls = false,
    this.disallowedExtensions = defaultDisallowedExtensions,
  });

  factory MediaLibraryConfig.fromEnv(Env env) {
    final queue = env.maybeString('MEDIA_QUEUE');
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
  };
}
