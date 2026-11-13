### Added

- `normalizeFilePath`: `normalizeDiskPath` for an operation on a file, refusing a path that names the disk root.

### Fixed

- Copying or moving a file onto itself (the same path once normalised) does nothing, on every disk: `LocalDisk.copy(a, a)` emptied the file on Linux, `MemoryDisk.move(a, a)` and `S3Disk.move(a, a)` (on a store that allows a self-copy) deleted it, and `ReadThroughDisk.move(a, a)` deleted it from the fallback. A missing file is still "not found", as Flysystem.
- A path that names the disk root (an empty one, `.`, `dir/..`) is no file on any disk (`LocalDisk`, `MemoryDisk`, `ReadThroughDisk`, `S3Disk`): `exists` is false, reads are "not found", and writes, copies, moves and URLs throw a `StorageException`. Before, `S3Disk` with an empty root signed and fetched the bucket itself (`temporaryUrl('.')` listed it), `MemoryDisk` stored a file named `''`, and `LocalDisk.put('.')` left `<root>.<µs>.tmp` beside the root. `LocalDisk.put` also removes its `.tmp` when the write or the rename fails, as `putStream` did.
