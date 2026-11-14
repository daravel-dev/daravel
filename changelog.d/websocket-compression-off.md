### Changed

- WebSocket compression (permessage-deflate) is off unless a route asks for it: `router.ws(..., compress: true)` or `Response.webSocket(..., compress: true)`; the default of `compress` and `Response.webSocketCompression` is now false. A small compressed message can inflate to its route's `maxPayloadBytes`, and nothing limited what one connection inflated over many messages. The Pusher server stays uncompressed, as Laravel Reverb (it does not negotiate permessage-deflate).

### Upgrade notes

- WebSocket compression is off unless a route asks for it. Clients keep working without a change, since compression is negotiated, not required; they connect uncompressed. A route that sends large text messages to clients over slow links sends more bytes now: add `compress: true` to it if its clients are known.
