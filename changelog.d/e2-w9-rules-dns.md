### Added

- `email` takes Laravel's modes (wave 9, W9.4a): `email:rfc,dns`, `email:filter`, `email:filter_unicode`, `email:strict` and `email:spoof`, or `Rules.email(rfc: true, dns: true, ...)`; the DSL no longer drops them. Every mode given must pass. `filter`/`filter_unicode` are PHP's `FILTER_VALIDATE_EMAIL`, read in one pass over the address instead of with PHP's regex, whose lookaheads backtrack exponentially without PCRE's backtrack limit (57 characters took 18 s in Dart); compared with PHP 8.3 on 3 857 addresses; `dns` follows egulias' `DNSCheckValidation` (reserved and single-label domains fail, a parent name may answer, a null MX fails, at most 4 names looked up per address); `rfc`/`strict` keep the current check until the egulias RFC parser is ported; `spoof` needs ICU and throws `UnsupportedError` when the rules are built (`Rules.email(spoof: true)`, or a `Validator` with `email:spoof`), not on each value checked. `dartisan lint` reports `spoof` and unknown modes.
- `active_url` / `Rules.activeUrl()`: the URL's host has an A or AAAA record; an IP address fails, as in Laravel.
- `DnsResolver` and `SystemDnsResolver`: A/AAAA through the operating system, MX through a small UDP client (random id and source port, answers only from the server asked and only to the question asked, bounded parsing, truncated or missing answers fall back to A/AAAA), 2 seconds per lookup. Bind another in the container; `daravel_test` has `FakeDnsResolver`, as Laravel's `fakeDnsLookups`.

### Upgrade notes

- `package:daravel` exports `DnsResolver` and `SystemDnsResolver`; `package:daravel_test` exports `FakeDnsResolver`.
- `email:dns`, `email:filter` and the other modes were accepted and ignored before (every `email` was the same check); they now apply. A rule `email:dns` now looks up the domain.
