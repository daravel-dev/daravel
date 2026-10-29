# Changelog

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Fixed: a request that times out is aborted (its socket leaked until the peer closed it), a response body that goes quiet for `timeout` is cut off with `ConnectionException`, and a connection reset during a send is a `ConnectionException` (it escaped as `dart:io`'s `HttpException`).
- Fixed: `readStream` downloads have the same quiet-body timeout as `get` (`S3Client.bodyStream`); a request whose `openUrl` finishes after the timeout is aborted too; only a connection closed or reset before a response is retried (not every `HttpException`); and `backoff` no longer overflows for large attempts.
- Added: `S3Client.retries` (3) and `retryDelay` (100 ms): 500, 502, 503 (`SlowDown`), 504 and a connection that fails before a response are retried with exponential jittered backoff (`backoff(attempt)`), as the AWS SDKs do.

## 1.13.0

- First release (Blueprint #52): `S3Disk`, a `Disk` on AWS S3 and S3-compatible stores (Cloudflare R2, MinIO, DigitalOcean Spaces, Google Cloud Storage), configured from Laravel's `AWS_*` variables; `SigV4Signer`, AWS Signature Version 4 in pure Dart, checked against AWS's published S3 examples; `putStream` that keeps at most one part in memory and switches to a multipart upload for large streams; server-side `copy`; batched `DeleteObjects`; `temporaryUrl` and `temporaryUploadUrl` (presigned `GET` and `PUT`), `temporaryUploadForm` (a presigned `POST` policy that caps size and content type); `withS3()`.
