### Fixed

- `distinct:ignore_case` now uses a static Unicode 15.0.0 simple case-folding table (status C and S, matching PCRE2 bundled with PHP 8.2-8.4) with a zero-allocation ASCII fast path, so `İ` (`U+0130`) and `ı` (`U+0131`) no longer fold to `i` and the 418 additional Unicode 14-15 equivalence classes are folded consistently across Dart SDK versions. `PhpValueIndex` now builds only the index needed for the active comparison mode and reuses per-attribute folded and numeric keys instead of recomputing them per item.
