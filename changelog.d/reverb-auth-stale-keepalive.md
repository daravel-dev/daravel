### Fixed

- `daravel_reverb_client`: `EchoAuth.bearer` and `EchoAuth.endpoint` now close their own HTTP client pool when a WebSocket connection is lost and retry a channel authorization `POST` once on a transport error (`ClientException`), so a stale keep-alive socket closed by a draining server during a rolling restart no longer leaves private or presence channels permanently unsubscribed after reconnect.
