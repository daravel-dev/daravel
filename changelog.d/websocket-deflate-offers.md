### Fixed

- On a WebSocket route with `compress: true`, a client's permessage-deflate offer naming a window size RFC 7692 does not allow (`server_max_window_bits` or `client_max_window_bits` outside 8 to 15, not a number, or with a leading zero) was agreed to, and the connection ended at its first frame. Such an offer is declined now, read the way the handshake reads it to agree (`HeaderValue.parse` with `,` between values, its first value and parameters), and so is any offer holding a quote or a backslash, which clients do not send: the connection is agreed to without compression and works.
