### Fixed

- `distinct` (with `strict` and `ignore_case` too) overflowed the stack, a 500, on a value nested a few thousand levels deep or on a list or map that contains itself, wherever the rule ran on input that the JSON depth limit did not stop (a `Validator` on data built in code, or `HTTP_JSON_MAX_DEPTH` raised or off). It walked every value to the bottom to list the ones its pattern matches; it now stops below the pattern's last part (`items.*` reads two levels), since nothing deeper can match, so the depth of the walk and the length of a key follow the pattern and not the input. What it decides is unchanged. `in_array`, whose `*` crosses dots, still walks the whole input.
- The same object twice among the values of `distinct` (an `UploadedFile` instance listed twice, in data built in code) is now a duplicate, with `strict` and `ignore_case` too, as PHP's `==` and `===` take one instance for equal to itself; it never was. `in_array` finds the same instance likewise. Two instances are still never equal (PHP's `==` compares the properties of two objects of one class; that is not imitated).
- `distinct` and `in_array` over many objects took time growing with the square of their number (20 000 objects under `distinct`: 6.8 s); objects are now counted by instance, in linear time. Dart records among the values (in data built in code) cost the same way; a record equals nothing, itself included, as before, and now costs constant time.

### Upgrade notes

- A `Validator` run on data that holds the same object instance twice under a `distinct` pattern now reports both as duplicates, and `in_array` now accepts an object that is, by instance, one of the others. This needs one instance listed twice, which data built in code can do.
