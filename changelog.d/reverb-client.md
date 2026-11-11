### Added

- `daravel_reverb_client` (Blueprint #135, R4a): a Pusher protocol 7 client after Laravel Echo in pure Dart (VM, Flutter, web) for Laravel Reverb, Daravel and Pusher, without a dependency on the server. `Echo.reverb(key:, host:, path:, auth:)` with `channel`, `private`, `encryptedPrivate`, `join` (presence `here`/`joining`/`leaving`), `listen` with Laravel Echo's event names, `whisper`/`listenForWhisper`, `notification`, `leave`/`leaveAll`, `socketId` (`X-Socket-ID`), `connectionState`; pings by `activity_timeout`, reconnects with exponential backoff and jitter and subscribes again; cache channels; encrypted channels opened with the authorization's `shared_secret`; `EchoAuth.bearer`, `EchoAuth.endpoint`, `EchoAuth.custom`. `bench/interop` runs the Laravel Echo scenarios with it against Daravel and Laravel Reverb.

### Upgrade notes

- `daravel_reverb_client` is a new package, so nothing changes for an application that does not add it. Its public names are `Echo`, `EchoAuth`, `EchoAuthException`, `EchoConnectionState`, `EchoConnector`, `EchoListener`, `EchoMemberListener`, `EchoChannel`, `EchoPrivateChannel`, `EchoEncryptedChannel` and `EchoPresenceChannel` (an application class of one of these names and this package's import give an ambiguous-import error; `hide` it or rename yours).
