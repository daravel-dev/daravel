### Added

- Routing: `Router.postValidated`, `putValidated`, `patchValidated` and `deleteValidated` (wave 9, W9.5). They take a typed form request and a handler `(Request request, D data)` that receives its validated input as the request's input type: the same as `post(path, ...).validates(form)` (403, 422, the rules in OpenAPI), with `D` tied to the form, so a handler written for another request's input does not compile. New typedef `ValidatedHandler<D>`.

### Upgrade notes

- `package:daravel` exports the typedef `ValidatedHandler`. An application type of that name now needs a prefix or `hide`.
