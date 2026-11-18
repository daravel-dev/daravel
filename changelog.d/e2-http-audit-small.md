### Fixed

- Treat malformed maintenance bypass cookies (bad percent encoding or bytes that are not UTF-8) as invalid cookies; a valid bypass cookie of the same name after one of them still counts.
- Remove line breaks from server-sent event names.
- Finish a graceful server socket even when its connection stream was never listened to; a second `finish()` (or `stopAccepting()`) called while one is under way completes only when it is all done.
- Read `If-None-Match` by RFC 9110 for conditional file requests and `CacheHeadersMiddleware`: weak comparison, a comma or `*` inside quotes is part of the tag, `*` matches only as the whole value, all lines of the field are read, and a value that does not parse matches nothing (`200`, not `304`).
