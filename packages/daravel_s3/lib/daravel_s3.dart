/// S3 for Daravel: a [Disk] on AWS S3 or any S3-compatible store
/// (Cloudflare R2, MinIO, DigitalOcean Spaces, Google Cloud Storage),
/// signed with a pure Dart AWS Signature Version 4, with streaming
/// multipart uploads and presigned download and upload URLs.
///
/// ```dart
/// Application.configure(basePath: '.').withS3()
/// ```
library;

import 'package:daravel/daravel.dart' show Disk;

export 'src/client.dart';
export 'src/config.dart';
export 'src/disk.dart';
export 'src/setup.dart';
export 'src/signer.dart';
