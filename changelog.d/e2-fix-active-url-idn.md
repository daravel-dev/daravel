### Fixed

- `active_url` read the host through Dart's `Uri`, which percent-encodes and normalizes it, so it asked DNS for names Laravel never asks for: `b%c3%bccher.de` for `https://bücher.de/`, and `example.com` for `https://example.com./`, `https://ex%41mple.com/` or `http://example.com:65536/`, which then passed where Laravel fails. It now takes the host PHP's `parse_url` gives (checked against Laravel 13.40 on 91 URLs) and asks for it as Laravel does. A host DNS cannot answer as written (non-ASCII, a percent escape, a space, an empty label such as the one `example.com.` gives) fails without a lookup, as it never has an address in Laravel either. Hosts that `parse_url` reads and `Uri` did not are now looked up: `example.com:80` and `localhost:8080` without a scheme, and `1http://example.com`.

### Upgrade notes

- `active_url` can fail URLs it passed: a host ending in a dot, a percent escape in the host (`ex%41mple.com`), or a port above 65535. It can pass URLs it failed: `example.com:80` with no scheme. An internationalized host (`https://bücher.de/`) fails as before, now without a lookup. `email:dns` is unchanged: it converts an internationalized domain to punycode, as Laravel's egulias validation does.
