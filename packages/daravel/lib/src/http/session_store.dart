/// The session as code outside the session package sees it: Laravel's
/// `Illuminate\Contracts\Session\Session`, reduced to what the testing
/// toolkit reads and writes.
///
/// `package:daravel_session`'s `Session` implements it and puts the
/// session of a request in `request.attributes[SessionStore.attribute]`, so
/// `package:daravel_test` asserts on a response's session
/// (`assertSessionHas`) and seeds one (`withSession`) without depending on
/// the session package.
abstract interface class SessionStore {
  /// The key of a request's session in `Request.attributes`.
  static const String attribute = 'session';

  /// The key of a map of attributes the session middleware puts into the
  /// session when it starts it (`TestClient.withSession`). It is set in
  /// process only: nothing a client sends reaches `Request.attributes`.
  static const String seedAttribute = 'daravel.session.seed';

  /// The session id (the cookie value).
  String get id;

  /// Every attribute, including the framework's `_token`, `_flash` and
  /// `_previous` entries.
  Map<String, Object?> get all;

  /// Whether [key] (dotted) holds a non-null value.
  bool has(String key);

  /// Whether [key] is set, even to null.
  bool exists(String key);

  /// The value of [key] (dotted), or [fallback].
  T? get<T>(String key, [T? fallback]);

  /// Sets [key] to [value].
  void put(String key, Object? value);

  /// The CSRF token (`csrf_token()`).
  String? get token;

  /// The validation errors flashed by a failed request, by field.
  Map<String, Object?> get errors;

  /// `old('name')`: the flashed input of a failed request.
  T? old<T>(String key, [T? fallback]);
}
