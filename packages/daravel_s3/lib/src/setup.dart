import 'package:daravel/daravel.dart';

import 'config.dart';
import 'disk.dart';

/// `withS3()` on the application builder.
extension S3ApplicationBuilder on ApplicationBuilder {
  /// Adds the disk [disk] (default `s3`) from `AWS_*` in `.env`, so
  /// `Storage.disk('s3')` (or every `Storage` call, with
  /// `FILESYSTEM_DISK=s3`) reads and writes the bucket.
  ApplicationBuilder withS3({String disk = 's3'}) {
    final opened = <S3Disk>[];
    return withConfig<S3Config>(S3Config.fromEnv)
        .withConfigCheck(S3Config.check)
        .withBindings(
          (container) => container.extend<StorageManager>(
            (manager, c) => manager
              ..extend(disk, () {
                final s3 = S3Disk.fromConfig(
                  disk,
                  c.make<ConfigRepository>().section<S3Config>(),
                );
                opened.add(s3);
                return s3;
              }),
          ),
        )
        .withShutdown((_) async {
          for (final s3 in opened) {
            s3.client.close();
          }
          opened.clear();
        });
  }
}

/// Presigned URLs on any [Disk], as Laravel's `Storage::disk('s3')`
/// offers them. An [S3Disk] signs them; a `Storage.fake()` disk returns a
/// placeholder URL so code that hands them out can be tested; any other
/// disk throws [StorageException].
extension S3TemporaryUrls on Disk {
  /// See [S3Disk.temporaryUrl].
  String temporaryUrl(
    String path, {
    required DateTime expiration,
    String? responseContentType,
    String? responseContentDisposition,
  }) => switch (this) {
    final S3Disk s3 => s3.temporaryUrl(
      path,
      expiration: expiration,
      responseContentType: responseContentType,
      responseContentDisposition: responseContentDisposition,
    ),
    final MemoryDisk fake => _fakeUrl(fake, path, expiration),
    _ => throw StorageException(
      'Disk [$name] does not support temporary URLs.',
    ),
  };

  /// See [S3Disk.temporaryUploadUrl].
  S3PresignedRequest temporaryUploadUrl(
    String path, {
    required DateTime expiration,
    String? contentType,
    int? contentLength,
  }) => switch (this) {
    final S3Disk s3 => s3.temporaryUploadUrl(
      path,
      expiration: expiration,
      contentType: contentType,
      contentLength: contentLength,
    ),
    final MemoryDisk fake => S3PresignedRequest(
      'PUT',
      _fakeUrl(fake, path, expiration),
      {'content-type': ?contentType},
    ),
    _ => throw StorageException(
      'Disk [$name] does not support temporary upload URLs.',
    ),
  };

  static String _fakeUrl(MemoryDisk disk, String path, DateTime expiration) =>
      '${disk.url(path)}?expiration='
      '${expiration.toUtc().millisecondsSinceEpoch ~/ 1000}';
}
