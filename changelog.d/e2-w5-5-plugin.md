### Added

- `daravel_lints_plugin` (W5.5): the `daravel_lints` rules as a Dart analysis server plugin (`analysis_server_plugin`), so `dartisan lint`'s findings appear in the editor and in `dart analyze`, with the same messages, the same `// daravel-lint-ignore:` comments (and the analyzer's `// ignore:`) and the same paths skipped. The default rules are warning rules (on once the plugin is enabled), the opt-in ones lint rules (enabled under `diagnostics:`). It is a package of its own because `analysis_server_plugin` pins `analyzer` to one exact version per release; the analysis server resolves the plugin apart from the application, so that pin never reaches an application's dependencies. Enable it with `plugins: daravel_lints_plugin: ^1.27.0` in `analysis_options.yaml` once it is published.

### Upgrade notes

- New package `daravel_lints_plugin` (exports `DaravelLintsPlugin` and `DaravelAnalysisRule`). Nothing changes for an application until it lists the plugin in `analysis_options.yaml`; `dartisan new` will add that line once the package is published.
