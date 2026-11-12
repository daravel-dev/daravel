### Added

- `dartisan request:sync [Request] [--check]` (wave 9, W9.5): writes the typed input of a `FormRequest<Input>` from its `static const x = Field<T>('key')` constants into a `// <dartisan:input>` region (an extension type over `ValidatedData` with one getter per field); `--check` writes nothing and exits 1 when a region is out of date, for CI. An input type declared by hand without the region, and an untyped `FormRequest`, are left as they are.

### Changed

- `make:request` writes a typed form request: `extends FormRequest<XInput>`, an example `Field`, rules keyed by it, and the `<dartisan:input>` region that `request:sync` keeps up to date. Untyped requests keep working.

### Upgrade notes

- `package:dartisan_cli` exports `RequestSyncCommand`, `RequestSource`, `RequestField`, `RequestSync`, `syncRequestSource` and `inputRegion` (from `src/request_sync.dart`).
