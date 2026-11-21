### Fixed

- `dartisan doctor` run inside a deployed `dartisan build --with-cli` bundle (#456) reported a *Project root* error, because a bundle has no `pubspec.yaml` on purpose, so a deploy gate on its exit status failed for a healthy release. A directory with a `bin/server` executable and no `pubspec.yaml` (the working directory, or the one `bin/dartisan` runs from) is now reported as *Build bundle at …*, the `.env` checks run against it, and only the source-tree checks (`package_config.json`) are skipped.

### Upgrade notes

- New public function `buildBundleRoot` in `package:dartisan_cli` (an application function of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
