### Fixed

- Treat malformed maintenance bypass cookies (bad percent encoding or bytes that are not UTF-8) as invalid cookies; a valid bypass cookie of the same name after one of them still counts.
- Remove line breaks from server-sent event names.
- Finish a graceful server socket even when its connection stream was never listened to.
- Match weak entity tags, lists and wildcards in conditional file requests.
