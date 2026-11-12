### Added

- `Response.downloadBytes(bytes, name:)` and `Response.streamDownload(stream, name:)` (#323), downloads of content made for the request, as Laravel's `response()->streamDownload()`: the type comes from the name's extension (`mimeTypeOf`), else `application/octet-stream`, unless `contentType` is given, and the `Content-Disposition` is `contentDisposition(name)`. `streamDownload` writes the stream as it is produced; a client that goes away cancels it, and a `HEAD` request never starts it. The Responses guide (EN/ID) shows both under "Content made for the request".

### Upgrade notes

- New public names in `package:daravel/daravel.dart`: `Response.downloadBytes` and `Response.streamDownload`.
