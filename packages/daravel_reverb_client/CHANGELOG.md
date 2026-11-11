# Changelog

## Unreleased

Not on pub.dev yet: first published with the Daravel release after 1.27.0.

- First release (Blueprint #135, R4a): `Echo.reverb(key:, host:, path:, auth:)` with `channel`, `private`, `encryptedPrivate`, `join`, `listen`/`stopListening`/`listenToAll`, presence `here`/`joining`/`leaving`, `whisper`/`listenForWhisper`, `leave`/`leaveChannel`/`leaveAll`, `socketId`, `connectionState` and `onConnectionStateChange`; pings by `activity_timeout`, reconnects with exponential backoff and jitter and resubscribes; cache channels; encrypted channels opened with the authorization's `shared_secret`; `EchoAuth.bearer`, `EchoAuth.endpoint`, `EchoAuth.custom`.
