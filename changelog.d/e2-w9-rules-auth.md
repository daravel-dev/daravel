### Added

- `current_password` / `current_password:guard` and `Rules.currentPassword(guard:)` (wave 9, W9.4a): the password of the user signed in on the guard; a guest fails. `Rules.can(ability, [arguments])` (`Rule::can`): the gate allows the current user the ability with the arguments and the value, PHP's empty values left out as Laravel's `array_filter`. Both ask through interfaces the validation module owns, `CurrentPasswordVerifier` and `AbilityChecker`, which the Application binds from the auth module; a `Validator` outside an Application throws a `StateError` naming what to bind instead of passing.

### Upgrade notes

- `package:daravel` exports `CurrentPasswordVerifier`, `AbilityChecker`, `CurrentPasswordRule` and `CanRule` (from `src/validation/auth_rules.dart`).
