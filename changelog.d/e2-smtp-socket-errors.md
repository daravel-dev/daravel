### Fixed

- Mail: `SmtpTransport` no longer lets socket and TLS errors out as they are. A refused or failed connection, a failed STARTTLS handshake (or its timeout) and a connection the server resets are an `SmtpException` whose new `cause` holds the original `SocketException`, `TlsException` or `TimeoutException`; a write to a connection the server reset, which failed on the socket's unobserved done future and escaped to the caller's zone as a bare `SocketException` (seen on macOS in CI), now fails the next reply instead.

### Added

- `SmtpException.cause` and `SmtpException.connection(message, cause)`.
