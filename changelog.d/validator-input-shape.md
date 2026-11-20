### Fixed

- Security: an empty key was dropped from the paths `in_array` builds, so a value under an empty top-level key could stand in for a named field (`{"": {"allowed": [...]}}` fed `in_array:allowed.*.code`). An empty key is now an empty segment, as Laravel's `Arr::dot` writes it: `in_array` sees it at `.allowed.0.code`.
