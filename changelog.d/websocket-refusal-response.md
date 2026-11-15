### Fixed

- Load-shed responses during shutdown close their HTTP connections.
- Refused WebSocket upgrades use the ordinary response lifecycle, including request body handling and request termination.
