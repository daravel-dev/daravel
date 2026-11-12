### Added

- `HTTP_JSON_MAX_DEPTH` (default 512) sets how deep a JSON request body may nest, with the meaning of PHP's `json_decode` `$depth`, which Laravel reads bodies with: arrays and objects nested 511 deep are read, and a body nested 512 deep or deeper is read as no input at all, as in Laravel 13 (checked against a golden of 94 bodies run through Laravel 13.40). The same limit applies to served requests and to the test client. `dartisan doctor` warns in production when it is `0` (off) or above 1 024.

### Fixed

- A JSON body nested a few thousand levels deep answered 500 (a stack overflow): from 2 345 levels in `distinct`, from 3 433 in a response echoing the input. The nesting is now counted on the bytes in one pass before decoding, so such a body never reaches code that walks the input recursively. `BodyLimitsMiddleware`'s `jsonDepth` check counts the same way, so a body far past it is a 400, never a 500.

### Upgrade notes

- Upgrading can change what a request reads: a JSON body nested 512 levels deep or deeper, which was read (or answered 500), is now no input at all, so its validation fails as Laravel's does (`required` gives 422). Set `HTTP_JSON_MAX_DEPTH` higher (at most 1 024, which `doctor` accepts) where deeper bodies are expected, or `0` for no limit.
- New public names in `package:daravel/daravel.dart`: `Request.jsonMaxDepth`, `Request.defaultJsonMaxDepth`, `Request.jsonMaxDepthFromEnv` and the `jsonMaxDepth` parameter of `HttpKernel`.
