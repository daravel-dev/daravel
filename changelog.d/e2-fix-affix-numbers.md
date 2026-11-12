### Fixed

- `starts_with` and `ends_with` failed every number, where Laravel 13 casts a number to text as PHP does: `123` starts with `1`, `1.0` ends with `1`, `-5` starts with `-`. An empty parameter (`starts_with:,a`, or one left by a trailing comma) matched every string, so any string passed; `Str::startsWith` skips it, as `doesnt_start_with` and `doesnt_end_with` already did. The four rules now share one reading, checked against a golden of 1 344 cases from Laravel 13.40.
