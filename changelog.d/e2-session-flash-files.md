### Added

- `withSession(dontFlash: [...])` (Laravel's `$exceptions->dontFlash()`): keys, in dot notation as `Arr::forget`, that a failed validation does not flash back, added to `defaultDontFlash` (`current_password`, `password`, `password_confirmation`). `flashableInput` gives the input a redirect flashes.

### Fixed

- A form that fails validation with an uploaded file below its top level (`files[0]`, `user[avatar]`) is redirected back with its input flashed, files left out at any depth as Laravel's `RedirectResponse::removeFilesFromInput` does, instead of a `500` (the session could not serialize the file). A list that loses a file keeps the other indices, as a PHP array does.
