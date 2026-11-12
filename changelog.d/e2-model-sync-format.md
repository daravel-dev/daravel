### Changed

- `model:sync` lays out the code it writes into the `<dartisan:accessors>`, `<dartisan:statics>` (when it fills an empty one) and `<dartisan:ids>` regions as `dart format` would for the project (its SDK language version and `formatter: page_width`), so a synced model stays format-clean whatever the length of its model and column names. Code outside the regions is never touched; a region the formatter cannot parse is written as generated, with a warning. `dartisan_cli` depends on `dart_style` for this.
- `request:sync` (and `make:request`) lay out the `<dartisan:input>` region with the same formatter, for the project's language version and page width, instead of a hand layout fixed at 80 columns.

### Added

- `model:sync --check` writes nothing and exits 1 when a model is out of date with the schema, as `request:sync --check` does, for CI. The CI of this repository now migrates the starter and runs both checks.

### Upgrade notes

- The next `model:sync` rewrites the layout of the accessors region once in models with long names (lines that `dart format` would split are now written split); run it once and commit the result. Nothing changes in models that were already format-clean.
