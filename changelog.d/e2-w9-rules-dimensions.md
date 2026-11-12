### Added

- `dimensions` / `Rules.dimensions(...)` (wave 9, W9.4a): Laravel's image size constraints (`width`, `height`, `min_*`, `max_*`, `ratio`, `min_ratio`, `max_ratio`, ratios read as PHP's `sscanf('%f/%d')`), with the size read from the upload's header as PHP's `getimagesize` for PNG, GIF, JPEG, WebP and BMP (checked against PHP 8.2 on 16 headers). Only the first 256 KiB are read, every offset is checked, and a cut or malformed header fails the rule; an SVG passes. With this, every rule of Laravel 13's `validation.php` has a Daravel string rule or builder.
