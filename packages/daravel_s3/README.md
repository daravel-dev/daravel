<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_s3

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_s3/README.id.md)

A [Daravel](https://pub.dev/packages/daravel) `Storage` disk on AWS S3 and
S3-compatible stores: Cloudflare R2, MinIO, DigitalOcean Spaces, Backblaze
B2, Wasabi and Google Cloud Storage. It reads Laravel's `AWS_*` variables,
so a Laravel and a Daravel application share one `.env` and one bucket.

```bash
dart pub add daravel_s3
```

```dart
Application.configure(basePath: '.').withS3() // AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET, ...

await Storage.disk('s3').put('avatars/1.png', bytes);
await video.store('recordings', disk: 's3'); // multipart, one part in memory

final url = Storage.disk('s3').temporaryUrl('invoices/1029.pdf', expiration: 30.minutes.fromNow);
final upload = Storage.disk('s3').temporaryUploadUrl('materials/a.mp4',
    expiration: 15.minutes.fromNow, contentType: 'video/mp4'); // url + headers for the client
```

- AWS Signature Version 4 in pure Dart, checked against AWS's published S3
  examples; no AWS SDK, one AOT binary.
- Every `Disk` method, held to the same contract tests as the core's
  `LocalDisk` and `MemoryDisk`; server-side copy, batched deletes.
- Streams upload in 8 MiB parts and download as they arrive.
- Presigned download and direct upload URLs, and POST forms that cap an
  upload's size and type; all also on `Storage.fake()`.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/s3.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; Amazon S3 and AWS are trademarks of Amazon.com,
Inc. or its affiliates; Cloudflare R2 is a trademark of Cloudflare, Inc.
Daravel is an independent project, not affiliated with or endorsed by any
of them.
