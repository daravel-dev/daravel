### Fixed

- Bound the number of query and URL-encoded form pairs before building nested input.

### Upgrade notes

- Query strings and URL-encoded forms with more than 1,000 nonempty pairs now return 400 when read instead of accepting all input. Set `HTTP_MAX_INPUT_VARS` to a positive limit appropriate for the application; PHP instead warns and truncates excess input. Multipart retains its separate part limit.
