### Fixed

- `dartisan upgrade` during a release that is not on pub.dev for every package yet (as 1.27.1 was for about an hour) rewrote `pubspec.yaml` to the new version and then failed in `dart pub upgrade`, leaving a project that could not resolve. It now asks pub.dev, before it writes anything, for each package it would move and for `dartisan_cli` (unless `--no-global`) at the target version; when one is missing it names it and changes nothing. When `dart pub upgrade` fails, `pubspec.yaml` and `pubspec.lock` are restored. `UpgradeCommand(published:)` takes the check for tests.

### Upgrade notes

- New public names `PublishedVersion` and `pubDevHasVersion` in `package:dartisan_cli`, and `UpgradeCommand(checkDeadline:)` (30 s) with `UpgradeCommand.checkBatch` (8 requests at once): a project command file that declares one of them and imports the barrel gets an ambiguous-import error (`hide` them or rename yours). `dartisan upgrade` now needs pub.dev to answer for each package; offline it changes nothing and says so.
