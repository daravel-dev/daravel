import 'package:daravel/daravel.dart';

/// The `s3` disk from `.env`, under the names of Laravel's
/// `config/filesystems.php`: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
/// `AWS_DEFAULT_REGION`, `AWS_BUCKET`, `AWS_URL`, `AWS_ENDPOINT` and
/// `AWS_USE_PATH_STYLE_ENDPOINT`, plus `AWS_SESSION_TOKEN` (temporary
/// credentials) and `AWS_VISIBILITY` (`private` or `public`).
final class S3Config implements ConfigSection {
  const S3Config({
    this.accessKey = '',
    this.secretKey = '',
    this.region = 'us-east-1',
    this.bucket = '',
    this.url,
    this.endpoint,
    this.usePathStyleEndpoint = false,
    this.sessionToken,
    this.root = '',
    this.visibility = 'private',
  });

  factory S3Config.fromEnv(Env env) => S3Config(
    accessKey: env.string('AWS_ACCESS_KEY_ID', ''),
    secretKey: env.string('AWS_SECRET_ACCESS_KEY', ''),
    region: env.string('AWS_DEFAULT_REGION', 'us-east-1'),
    bucket: env.string('AWS_BUCKET', ''),
    url: env.maybeString('AWS_URL'),
    endpoint: env.maybeString('AWS_ENDPOINT'),
    usePathStyleEndpoint: env.boolean('AWS_USE_PATH_STYLE_ENDPOINT'),
    sessionToken: env.maybeString('AWS_SESSION_TOKEN'),
    visibility: env.string('AWS_VISIBILITY', 'private'),
  );

  /// `AWS_ACCESS_KEY_ID`.
  final String accessKey;
  final String secretKey;
  final String region;
  final String bucket;

  /// The public base URL of [S3Disk.url] (a CDN in front of the bucket);
  /// without it URLs point at the bucket itself.
  final String? url;

  /// An S3-compatible endpoint (R2, MinIO, Spaces, GCS); AWS when `null`.
  final String? endpoint;

  /// `endpoint/bucket/key` instead of `bucket.endpoint/key` (MinIO).
  final bool usePathStyleEndpoint;

  final String? sessionToken;

  /// A prefix every key of the disk lives under (Laravel's `root`).
  final String root;

  /// `public` sends `x-amz-acl: public-read` with each write.
  final String visibility;

  /// Errors for an `s3` default disk without credentials or a bucket.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    if (config.section<StorageConfig>().defaultDisk != 's3') {
      return const [];
    }
    final s3 = config.section<S3Config>();
    return [
      for (final (name, value) in [
        ('AWS_ACCESS_KEY_ID', s3.accessKey),
        ('AWS_SECRET_ACCESS_KEY', s3.secretKey),
        ('AWS_BUCKET', s3.bucket),
      ])
        if (value.isEmpty)
          ConfigIssue(
            ConfigIssueLevel.error,
            'S3: FILESYSTEM_DISK is s3 but $name is empty.',
          ),
      if (s3.visibility != 'private' && s3.visibility != 'public')
        ConfigIssue(
          ConfigIssueLevel.error,
          'S3: AWS_VISIBILITY must be private or public, not '
          '${s3.visibility}.',
        ),
    ];
  }

  @override
  String get key => 's3';

  @override
  Map<String, Object?> toMap() => {
    'driver': 's3',
    'key': accessKey,
    'secret': secretKey.isEmpty ? '' : '********',
    'region': region,
    'bucket': bucket,
    'url': url,
    'endpoint': endpoint,
    'use_path_style_endpoint': usePathStyleEndpoint,
    'token': sessionToken == null ? null : '********',
    'root': root,
    'visibility': visibility,
  };
}
