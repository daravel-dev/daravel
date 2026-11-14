### Changed

- WebSocket compression (permessage-deflate) is off unless a route asks for it: `router.ws(..., compress: true)` or `Response.webSocket(..., compress: true)`; the default of `compress` and `Response.webSocketCompression` is now false. A small compressed message can inflate to its route's `maxPayloadBytes`, and nothing limited what one connection inflated over many messages. The Pusher server stays uncompressed, as Laravel Reverb (it does not negotiate permessage-deflate).
- The warnings for a WebSocket violation and a slow client, and the error of a WebSocket handler, name the request's path besides its id.

### Fixed

- A WebSocket whose handler cancelled its subscription and kept the socket open stayed open until the server stopped: the client's close and its going away were no longer read. The client is read on, within the bound of what a handler that does not read gets: its close or its going away ends the session at once, with its code, and more than the bound sent unread ends it with 1008 after 5 s. What the handler sends is not affected.

### Upgrade notes

- WebSocket compression is off unless a route asks for it. Clients keep working without a change, since compression is negotiated, not required; they connect uncompressed. A route that sends large text messages to clients over slow links sends more bytes now: add `compress: true` to it if its clients are known.
- A WebSocket destroyed by the server for a client that reads too slowly (its PONGs over `maxBufferedBytes`), with no close frame either way, reports `socket.closeCode` 1006 (abnormal closure, RFC 6455 section 7.1.5) where it reported null.
