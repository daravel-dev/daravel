### Fixed

- What the server holds for a WebSocket handler that does not read stays within its bound (64 KiB, or the route's `maxPayloadBytes` if smaller, plus one message or 64 KiB of frames) whatever the size of one read from the connection: the server stops parsing there, and the rest of the last read waits unparsed until the handler reads (one read per connection, as large as the system's receive buffer lets it be), while TCP holds the client back.
