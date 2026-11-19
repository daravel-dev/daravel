### Fixed

- Security: `distinct` compared values only when their parent was a list, found from the attribute's depth. Duplicates in a JSON object (`{"items": {"a": {"id": 1}, "b": {"id": 1}}}`), in a form with sparse or out-of-order indexes (`items[1][id]=7&items[3][id]=7`), under `a.b.*` and under `*.id` passed. `distinct` now compares every value its pattern matches, whatever holds them: with one `*`, all of them, as Laravel does; with more, the values that share every `*` but the last (the items of one parent), as this version did. A value under an empty key is compared with the others, and theirs not with it, as in Laravel.

### Upgrade notes

- `distinct` now answers `422` for duplicates it used to pass: values in a JSON object or a sparse form, under a fixed level before the wildcard (`a.b.*`) and under a top-level wildcard (`*.id`). Lists are compared as before, with one exception: `distinct` no longer counts an item that lacks the field, so `[{}, {"id": null}]` against `items.*.id` passes where it failed (the missing `id` was read as `null`), as in Laravel. With two or more wildcards (`a.*.items.*.id`), the same value under two different parents still passes in 1.27.x.
