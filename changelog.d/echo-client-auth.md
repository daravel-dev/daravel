### Added

- `daravel_reverb_client`: `EchoAuth.bearer` and `EchoAuth.endpoint` take a `timeout` (30 s by default); an authorization that takes longer fails with `EchoAuthException(channel, 0, 'timeout')`. Without a `client` of the application's, one HTTP client is made when first needed, used for every authorization and closed by `Echo.disconnect` (a client the application gives is not closed).

### Fixed

- `daravel_reverb_client`: an authorization is checked before the channel subscribes, by the built-in authorizers (with the HTTP status they got) and again for an `EchoAuth` of the application's (status 0): a JSON object with a string `auth`, `channel_data` a string when given, and for an encrypted channel a `shared_secret` that is the base64 of a 32-byte key. A 2xx answer that is not JSON (a login page, an empty body) used to throw a raw `FormatException` reported as status 0; it is now `EchoAuthException(channel, <status>, 'invalid json')`. A key of another length used to subscribe, and every event then failed to open; it is now refused before subscribing (`shared_secret is 16 bytes, not 32`). `Secretbox.poly1305` refuses a key that is not 32 bytes with an `ArgumentError`.
- `daravel_reverb_client`: the secretbox test vectors now run in a browser too (`dart test -p chrome`, a CI step on Linux), and a test checks the whole library compiles and works there; the tests that need `dart:io` are `@TestOn('vm')`.
