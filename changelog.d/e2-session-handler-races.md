### Fixed

- `daravel_session` file driver: `read` and `destroy` raced a sweep in another isolate or process (or Laravel's): a session file deleted between the check and the read or the delete threw `PathNotFoundException` or, on Windows while the deletion was pending, `PathAccessException`, and the request failed with a 500. A file that is gone, or going within a few milliseconds, now reads as no session and destroys quietly, as Laravel's `Filesystem::delete`; access refused on a file that stays is still an error.
- `daravel_session` file driver: the sweep deleted dotfiles (`.gitignore`, `.gitkeep`) in the sessions directory once they were older than the lifetime; it leaves names starting with `.` alone, as Laravel's `ignoreDotFiles(true)`.
- `FileSessionHandler` refuses a `gcBatch` below 1, with which a sweep never moved on.

### Upgrade notes

- Upgrading can change `FileSessionHandler`: a `gcBatch` below 1 now throws an `ArgumentError`. The `database` driver keeps Laravel's boundary: a session is still read at exactly its lifetime (`<`) and swept at it (`<=`), as Laravel 13's `DatabaseSessionHandler` does.
