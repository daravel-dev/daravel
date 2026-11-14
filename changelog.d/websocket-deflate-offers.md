### Fixed

- On a WebSocket route with `compress: true`, a client's permessage-deflate offer naming a window size RFC 7692 does not allow (`server_max_window_bits` or `client_max_window_bits` outside 8 to 15, not a number, with a leading zero, or given twice in one offer) was agreed to, and the connection ended at its first frame. Such an offer is declined now: the connection is agreed to without compression and works.
