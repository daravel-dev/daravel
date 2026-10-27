# Changelog

## 1.13.0

- First release (Blueprint #52): `S3Disk`, a `Disk` on AWS S3 and S3-compatible stores (Cloudflare R2, MinIO, DigitalOcean Spaces, Google Cloud Storage), configured from Laravel's `AWS_*` variables; `SigV4Signer`, AWS Signature Version 4 in pure Dart, checked against AWS's published S3 examples; `putStream` that keeps at most one part in memory and switches to a multipart upload for large streams; server-side `copy`; batched `DeleteObjects`; `temporaryUrl` and `temporaryUploadUrl` (presigned `GET` and `PUT`), `temporaryUploadForm` (a presigned `POST` policy that caps size and content type); `withS3()`.
