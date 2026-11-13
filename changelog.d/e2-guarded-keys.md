### Fixed

- `dartisan model:sync` decides which columns get `createWith`/`fillWith` parameters by the rule of `ModelDefinition.isFillable` (as in 1.27.5), so it no longer writes a parameter that `fill` discards (a column starting with `_`, or one guarded in another letter case).
