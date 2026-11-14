/// [url] with the password in its user info masked as `***`, for error
/// messages and logs: `pgsql://app:***@db/shop`.
///
/// It does not need a valid URL, so it also works on the URL a parser has
/// just rejected: whatever the scheme (any case, `+`), with or without
/// `//`, or without a scheme at all, everything between the first `:` of
/// the user info and the **last** `@` is masked, so a password holding `@`, `/`, `?` or `#` is
/// masked whole. An `@` later in the path or query masks more than the
/// password, never less. A URL without user info, or with a user and no
/// `:`, is returned as it is.
///
/// With [loneUserIsPassword], user info without a `:` is masked whole,
/// for schemes such as `redis://secret@host` where it is the password.
String redactUrlPassword(String url, {bool loneUserIsPassword = false}) {
  final at = url.lastIndexOf('@');
  if (at < 0) {
    return url;
  }
  // The user info starts after `://` when one comes before the `@`;
  // otherwise at the start of the text (after a leading `//`), so a URL
  // without a valid scheme (`app:secret@host`, `postgres//app:secret@h`)
  // is masked too. Masking more (`mailto:***@b`) is fine; less is not.
  final separator = url.indexOf('://');
  final user = separator >= 0 && separator < at
      ? separator + 3
      : (url.startsWith('//') ? 2 : 0);
  if (at < user) {
    return url;
  }
  final colon = url.indexOf(':', user);
  if (colon < 0 || colon > at) {
    return loneUserIsPassword && at > user
        ? '${url.substring(0, user)}***${url.substring(at)}'
        : url;
  }
  return '${url.substring(0, colon + 1)}***${url.substring(at)}';
}

/// Names whose values logs, error messages and URLs never show: a name
/// matches when, in lower case without `-` and `_` ([normalizeKeyName]),
/// it contains one of these the same way (`X-API-KEY`, `api_key` and
/// `apiKey` are one name) — BLUEPRINT_V2 §7.6.5. The logger's default
/// `LOG_REDACT` list and [redactUrl] both use it.
const List<String> sensitiveKeyNames = <String>[
  'password',
  'passwd',
  'pwd',
  'token',
  'authorization',
  'bearer',
  'cookie',
  'secret',
  'api_key',
  'apikey',
  'jwt',
  'session_id',
  'private_key',
  'credentials',
  'dsn',
  // Pusher's auth_signature, AWS's X-Amz-Signature: a signed request
  // replayed within its window.
  'signature',
];

/// [key] in lower case without `-` and `_`, as [sensitiveKeyNames] are
/// compared.
String normalizeKeyName(String key) =>
    key.toLowerCase().replaceAll('-', '').replaceAll('_', '');

/// Whether [key] names a value to hide: its [normalizeKeyName] contains
/// one of [names], compared the same way.
bool isSensitiveKeyName(String key, [List<String> names = sensitiveKeyNames]) {
  final normalized = normalizeKeyName(key);
  return names.any((name) => normalized.contains(normalizeKeyName(name)));
}

/// [url] for messages and logs: the password in its user info masked
/// ([redactUrlPassword]), and the value of every query parameter whose
/// name is sensitive ([isSensitiveKeyName]: `token`, `api_key`,
/// `password`, ...) replaced by `***`; other parameters stay
/// (`?token=***&page=2`). Like [redactUrlPassword], it needs no valid URL.
String redactUrl(
  String url, {
  bool loneUserIsPassword = false,
  List<String> names = sensitiveKeyNames,
}) {
  final masked = redactUrlPassword(url, loneUserIsPassword: loneUserIsPassword);
  final question = masked.indexOf('?');
  if (question < 0) {
    return masked;
  }
  final hash = masked.indexOf('#', question);
  final end = hash < 0 ? masked.length : hash;
  final pairs = [
    for (final pair in masked.substring(question + 1, end).split('&'))
      _maskPair(pair, names),
  ];
  return '${masked.substring(0, question + 1)}${pairs.join('&')}'
      '${masked.substring(end)}';
}

String _maskPair(String pair, List<String> names) {
  final equals = pair.indexOf('=');
  if (equals < 0) {
    return pair;
  }
  final raw = pair.substring(0, equals);
  String name;
  try {
    name = Uri.decodeQueryComponent(raw);
  } on Object {
    name = raw;
  }
  return isSensitiveKeyName(name, names) ? '$raw=***' : pair;
}
