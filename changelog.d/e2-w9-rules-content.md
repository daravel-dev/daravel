### Added

- Validation: the eleven content rules of Laravel 13 that Daravel lacked, as strings, `Rules.*` builders and chain steps, with Laravel's messages and placeholders: `contains`, `doesnt_contain`, `doesnt_start_with`, `doesnt_end_with`, `in_array`, `in_array_keys`, `array_keys` (13.x), `hex_color`, `mac_address`, `encoding` (UTF-8, ASCII, ISO-8859-1; another encoding PHP knows throws `UnsupportedError` when the rule runs, and `invalid_validation_rule` flags it), `base64` (13.x); `invalid_validation_rule` knows them (wave 9, W9.4a). `rule_completeness_test.dart` lists the Laravel 13 rules still missing: the five that need the outside world or are objects (`active_url`, `dimensions`, `current_password`, `can`, `any_of`).

### Upgrade notes

- `package:daravel` exports eight new rule classes: `ArrayValuesRule`, `DoesntAffixRule`, `InArrayRule`, `ArrayKeysRule`, `HexColorRule`, `MacAddressRule`, `EncodingRule`, `Base64Rule`. An application class of the same name now needs a prefix or `hide`.
