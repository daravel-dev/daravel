### Added

- `SharedResult<T>`: the result of one computation awaited by several callers that may run in different zones. Its future never fails; `value` raises the computation's error again, with its stack trace, in each caller's zone.

### Upgrade notes

- New public name `SharedResult` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
