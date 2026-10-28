# Changelog

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Added: `RoomServiceClient` retries a Twirp call whose connection failed before it was sent, or that LiveKit answered 502 or 503, up to `retries` (2) more times with exponential backoff and jitter from `retryDelay` (200 ms); timeouts and other answers are final. `backoff(attempt)` is public.
- Added: `Livekit.webhook` remembers each event id in the application's cache for `maxAge` plus the skew and refuses a repeat with 401, so a captured webhook replayed inside the window is refused too.
- Added `LivekitWebhookReceiver.maxAge` (`Livekit.webhook(request, maxAge:)`, five minutes, 30 s of skew): an event whose `created_at` is older, or in the future, is a 401, closing the replay window a token's lifetime left open; `null` keeps only the token check.
- Fixed: an empty API secret no longer signs or verifies anything (`LivekitToken.toJwt`, `LivekitToken.verify` and `LivekitWebhookReceiver.receive` throw `StateError`); with HS256 an empty key verified tokens signed with an empty key, so webhooks could be forged by anyone knowing the API key. Boot fails when `LIVEKIT_API_KEY` is set but `LIVEKIT_API_SECRET` is not.

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: `LivekitToken` and `VideoGrant` (access tokens with LiveKit's claims), `RoomServiceClient` (rooms, participants, data messages over Twirp, each call with a 10-minute token carrying only its grant), `LivekitWebhookReceiver` (signature, expiry, issuer and body SHA-256, always checked), `withLivekit()` and the `Livekit` facade.
