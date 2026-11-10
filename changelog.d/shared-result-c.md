### Fixed

- The Pusher server's relay start (`REVERB_SCALING_ENABLED`, Review #147): when the relay failed to start (Redis or the database down), only the first WebSocket connection waiting on it was refused with 4100, and the others that arrived meanwhile waited for ever. Each is now refused, and the next client starts the relay again, as before.
- `daravel_redis`: a connection that fails to open, and a cluster slot map that cannot be read, now reach every command waiting on them instead of leaving all but one waiting (Review #147).
- `daravel_google`: a user token refresh, and a service account token fetch, that fail now reach every request waiting on them instead of leaving all but one waiting (Review #147).
- `daravel_redis` queue: the blocking wait shared by the workers waiting on a slot no longer fails on an unexpected error (only connection and command errors were caught); it pauses and opens another connection, as on a command error.
