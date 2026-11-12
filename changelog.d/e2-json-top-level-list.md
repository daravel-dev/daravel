### Fixed

- A JSON body that is a list at the top (`[{"email": ...}, ...]`, a bulk import) was left out of `request.all()`, `input()` and validation, as if it were empty. Its elements are now the fields `'0'`, `'1'`, ..., as Laravel 13 reads them: `input('0.email')`, `has('0')` and rules on `*.email` reach them, checked against a golden run through Laravel 13.40. `body()` still gives the decoded list.

### Changed

- `request.all()` now lists the body's fields first, then the query parameters the body does not have, as Laravel's `input + query` does; it listed the query first. The values are the same; only the order changed, which shows where `all()` is returned as JSON or iterated, and in the order of `*` rules over the top level. `validated()` keeps the order of the rules, `only()` the order of the keys asked for and `except()` the order of the data, as in Laravel.

### Upgrade notes

- Upgrading can change what a request reads: a JSON list body, which reached validation as no input (so `required` failed), now gives its elements as fields `'0'`, `'1'`, ....
- The keys of `request.all()` come in a different order (body first, then the query); the values are unchanged. A test comparing `all()` as an ordered JSON string may need its expected text reordered.
