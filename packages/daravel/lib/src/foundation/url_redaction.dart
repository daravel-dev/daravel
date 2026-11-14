/// [url] with the password in its user info masked as `***`, for error
/// messages and logs: `pgsql://app:***@db/shop`.
///
/// It does not need a valid URL, so it also works on the URL a parser has
/// just rejected: whatever the scheme (any case, `+`), with or without
/// `//`, everything between the first `:` after the user name and the
/// **last** `@` is masked, so a password holding `@`, `/`, `?` or `#` is
/// masked whole. An `@` later in the path or query masks more than the
/// password, never less. A URL without user info, or with a user and no
/// `:`, is returned as it is.
///
/// With [loneUserIsPassword], user info without a `:` is masked whole,
/// for schemes such as `redis://secret@host` where it is the password.
String redactUrlPassword(String url, {bool loneUserIsPassword = false}) {
  final scheme = url.indexOf(':');
  if (scheme < 0) {
    return url;
  }
  var user = scheme + 1;
  if (url.startsWith('//', user)) {
    user += 2;
  }
  final at = url.lastIndexOf('@');
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
