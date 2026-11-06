# Changelog

## Unreleased

- First slice (Blueprint #134, H3a): `HorizonConfig` (`HORIZON_*`, supervisors as `SupervisorPlan`, `defaults` and `environments` resolved for `APP_ENV`, checks for `ConfigValidator`) and the auto-scaler `decide` (EWMA, Little's law, `time` and `size` strategies, `balanceMaxShift`, scaling down only after two calm evaluations).
