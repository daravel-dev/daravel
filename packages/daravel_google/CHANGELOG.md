# Changelog

## 1.21.1

- Version aligned with Daravel 1.21.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.0

- Version aligned with Daravel 1.21.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.1

- Version aligned with Daravel 1.20.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Version aligned with Daravel 1.19.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Version aligned with Daravel 1.18.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Added `Google.serviceCredentials` and `ServiceAccountCredentialsCache`: `Google.serviceCalendar()` shares one token per isolate, scopes and subject; it used to sign an RS256 assertion and call Google's token endpoint on every call.
- Added `GoogleOAuth.isRevoked`: the client remembers refresh tokens Google answered `invalid_grant` for (up to 1 000), so `UserCredentials` built afresh for each request (`Google.calendarFor`) do not ask Google again either; `UserCredentials.replace` also discards a refresh of the old token still in flight.
- Added `UserCredentials.revoked` and `replace`: once Google answers `invalid_grant` the credentials keep throwing it instead of asking Google's token endpoint again on every call (a busy page hammered it); `replace` installs the token of a new consent.
- Fixed: `UserCredentials` stores a refreshed token (`onRefresh`) before keeping it; when the store failed, the token in memory was already the new one and the next call never retried the store.

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: `GoogleToken` (google/apiclient's token JSON), `GoogleOAuth` (consent URL with offline access, code exchange, refresh, revoke), `GoogleServiceAccount` (key files, RS256 assertions per RFC 7523, domain-wide delegation), `UserCredentials` and `ServiceAccountCredentials` (refreshed a minute early, one refresh for concurrent calls), `GoogleCalendar` (events with guests and Google Meet links: create, get, list, patch, replace, delete), `withGoogle()` and the `Google` facade.
