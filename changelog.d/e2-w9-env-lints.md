### Added

- `daravel_lints`: the opt-in rule `raw_env_outside_config` (`RawEnvOutsideConfig`) reports an environment variable read in application code outside `lib/config/`: `env('X')`, `make<Env>()`, `EnvKeys.*` or `Platform.environment`. As in Laravel, the environment belongs to the configuration, whose sections are validated at boot and frozen; read the value through a section. New projects and the starter enable it in their architecture test (`expectLintClean(null, ['raw_env_outside_config'])`).

### Upgrade notes

- New public name `RawEnvOutsideConfig` in `package:daravel_lints`. An existing project is unaffected until it enables the rule by name. A project that does should move each reported read into a config section, or silence a deliberate one with `// daravel-lint-ignore: raw_env_outside_config`.
