### Fixed

- Security: `validated()` read a map key from the client as a list index when it looked like a number. `{"items": {"20000000": "a"}}` (or the form `items[20000000]=a`) against `items.*` built a list of 20 000 001 entries, and `"-1"` failed with a `500`. Each level of `validated()` now has the shape it has in the input: a map stays a map with its keys as sent, a list stays a list, and no key decides the length of a list.
- Security: a `.` or `*` in a key of the data was read as a level or a wildcard, so `{"items": {"a.b": {"role": "admin"}}}` passed `items.*.role` against `in:member` without the rule running. Such keys are now keys, as in Laravel (which replaces them with placeholders while the rules run): the rules under a wildcard apply to that element, and its error is reported under the key as sent (`items.a.b.role`).

### Upgrade notes

- `validated()` keeps a JSON object as a map also when its keys are numbers: `{"items": {"0": "a", "1": "b"}}` used to come out as the list `["a", "b"]` and now comes out as that map. JSON lists and form fields (`items[0][name]`, already a list) are unchanged. Under an `array` rule, `ValidatedData.list()` still reads a map keyed `"0"`, `"1"`, ... in order as a list; any other map throws, and the `list` rule takes only a list (an object is a `422`).
