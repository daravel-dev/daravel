# Changelog

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: `LivekitToken` and `VideoGrant` (access tokens with LiveKit's claims), `RoomServiceClient` (rooms, participants, data messages over Twirp, each call with a 10-minute token carrying only its grant), `LivekitWebhookReceiver` (signature, expiry, issuer and body SHA-256, always checked), `withLivekit()` and the `Livekit` facade.
