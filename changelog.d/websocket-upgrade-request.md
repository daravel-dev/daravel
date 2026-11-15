### Changed
- WebSocket upgrades use a shared GET/HTTP 1.1 predicate. A single `Upgrade: websocket` value and an exact `upgrade` token across all `Connection` lines select the upgrade path. Other requests receive an ordinary response.

### Upgrade notes
- `isWebSocketUpgrade` accepts repeated `Connection` lines and matches complete tokens. HEAD requests receive 426 on WebSocket routes. `Request.protocolVersion` records the incoming HTTP version and is 1.1 for synthetic requests.
- HTTP/1.0 requests are not upgraded.
