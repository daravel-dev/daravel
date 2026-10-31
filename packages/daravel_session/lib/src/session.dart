import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'handlers.dart';

/// One request's session (Laravel's `Illuminate\Session\Store`): a map of
/// attributes loaded from a [SessionHandler] at the start of the request
/// and written back at its end, so a Laravel application sharing the store
/// reads the same session.
///
/// Both of Laravel's formats are read, PHP `serialize()` and JSON. A session
/// is written back in the format it was read in, whatever [serialization]
/// says: rewriting a row in the other format would log the user out of the
/// Laravel application. [serialization] decides for new sessions only.
///
/// Flash data (`_flash.new`, `_flash.old`), the CSRF token (`_token`) and
/// the previous URL (`_previous.url`) use Laravel's keys.
final class Session {
  Session({
    required this.name,
    required this.handler,
    String? id,
    this.encrypter,
    this.serialization = 'php',
  }) : _id = id != null && isValidId(id) ? id : generateId(),
       _format = serialization;

  /// Length of a session id and of the CSRF token.
  static const int idLength = 40;

  /// The cookie name.
  final String name;
  final SessionHandler handler;

  /// With `SESSION_ENCRYPT`, the encrypter of the payload: Laravel's
  /// `EncryptedStore` stores `Crypt::encrypt(serialize($attributes))`, a
  /// serialized string inside the `Crypt` payload.
  final Encrypter? encrypter;

  /// `php` or `json`: the format of a session that has no stored payload
  /// yet (`SESSION_SERIALIZATION`).
  final String serialization;

  /// Cookies [StartSessionMiddleware] adds to the response, by name: a
  /// `null` value forgets the cookie.
  final Map<String, (String?, Duration?)> queuedCookies = {};

  String _id;
  String _format;
  final Map<String, Object?> _attributes = <String, Object?>{};
  bool _started = false;

  /// The session id (the cookie value).
  String get id => _id;

  /// Whether [start] has run.
  bool get isStarted => _started;

  /// Every attribute, including the framework's `_token`, `_flash` and
  /// `_previous` entries.
  Map<String, Object?> get all => Map.unmodifiable(_attributes);

  /// The session of the current request, or `null` outside one (a job, a
  /// route without `StartSessionMiddleware`).
  static Session? get current {
    try {
      return Container.current.currentScope?.get<Session>();
    } on StateError {
      return null;
    }
  }

  /// 40 alphanumeric characters (Laravel's `isValidId`).
  static bool isValidId(String id) =>
      id.length == idLength && RegExp(r'^[A-Za-z0-9]+$').hasMatch(id);

  static String generateId() => Str.random(idLength);

  /// Loads the attributes from the handler and makes sure a CSRF token
  /// exists.
  Future<void> start() async {
    var payload = await handler.read(_id);
    if (payload != null && payload.isNotEmpty && encrypter != null) {
      try {
        payload = await encrypter!.decrypt<String>(payload);
      } on DecryptException {
        // EncryptedStore::prepareForUnserialize: an empty session.
        payload = null;
      }
    }
    if (payload != null && payload.isNotEmpty) {
      try {
        final php = looksPhpSerialized(payload);
        final Object? data = php
            ? phpUnserialize(payload)
            : jsonDecode(payload);
        if (data is Map) {
          data.forEach((key, value) => _attributes['$key'] = value);
          _format = php ? 'php' : 'json';
        }
      } on FormatException {
        // An unreadable session starts empty, as Laravel's does.
      }
    }
    if (!has('_token')) {
      regenerateToken();
    }
    _started = true;
  }

  /// Ages the flash data and writes the attributes back.
  Future<void> save({Request? request}) async {
    ageFlashData();
    final serialized = _format == 'json'
        ? jsonEncode(_attributes)
        : phpSerialize(_attributes);
    await handler.write(
      _id,
      encrypter == null ? serialized : await encrypter!.encrypt(serialized),
      request: request,
    );
    _started = false;
  }

  // -- Attributes -----------------------------------------------------------

  bool has(String key) => _get(key) != null;

  bool exists(String key) => _lookup(key).$1;

  bool missing(String key) => !exists(key);

  T? get<T>(String key, [T? fallback]) {
    final value = _get(key);
    return value is T ? value : fallback;
  }

  void put(String key, Object? value) => _set(key, value);

  /// Gets [key] and forgets it.
  T? pull<T>(String key, [T? fallback]) {
    final value = get<T>(key, fallback);
    forget(key);
    return value;
  }

  /// Appends [value] to the list under [key].
  void push(String key, Object? value) {
    final list = get<List<Object?>>(key) ?? <Object?>[];
    put(key, [...list, value]);
  }

  int increment(String key, [int amount = 1]) {
    final value = (get<num>(key) ?? 0).toInt() + amount;
    put(key, value);
    return value;
  }

  int decrement(String key, [int amount = 1]) => increment(key, -amount);

  /// Puts [key] only when it is missing.
  T remember<T>(String key, T Function() value) {
    if (exists(key)) {
      return get<T>(key) as T;
    }
    final created = value();
    put(key, created);
    return created;
  }

  void forget(String key) => _remove(key);

  void flush() => _attributes.clear();

  // -- Flash data -----------------------------------------------------------

  /// Keeps [value] for the next request only.
  void flash(String key, [Object? value = true]) {
    put(key, value);
    push('_flash.new', key);
    _removeFromOldFlash([key]);
  }

  /// Keeps [value] for this request only.
  void now(String key, Object? value) {
    put(key, value);
    push('_flash.old', key);
  }

  /// Keeps every flashed value for one more request.
  void reflash() {
    _mergeNewFlashes(_stringList('_flash.old'));
    put('_flash.old', <Object?>[]);
  }

  /// Keeps the given flashed [keys] for one more request.
  void keep(List<String> keys) {
    _mergeNewFlashes(keys);
    _removeFromOldFlash(keys);
  }

  /// Laravel's `ageFlashData`: forgets last request's flash data and
  /// marks this request's as old.
  void ageFlashData() {
    for (final key in _stringList('_flash.old')) {
      forget(key);
    }
    put('_flash.old', get<List<Object?>>('_flash.new') ?? <Object?>[]);
    put('_flash.new', <Object?>[]);
  }

  void _mergeNewFlashes(List<String> keys) {
    final merged = <Object?>{..._stringList('_flash.new'), ...keys}.toList();
    put('_flash.new', merged);
  }

  void _removeFromOldFlash(List<String> keys) {
    put('_flash.old', [
      for (final key in _stringList('_flash.old'))
        if (!keys.contains(key)) key,
    ]);
  }

  List<String> _stringList(String key) => [
    for (final item in get<List<Object?>>(key) ?? const <Object?>[]) '$item',
  ];

  // -- Token, id and previous URL --------------------------------------------

  /// The CSRF token.
  String? get token => get<String>('_token');

  void regenerateToken() => put('_token', Str.random(idLength));

  /// Gives the session a new id, keeping its data (Laravel's
  /// `regenerate`); with [destroy] the old record is deleted.
  Future<void> regenerate({bool destroy = false}) async {
    await migrate(destroy: destroy);
    regenerateToken();
  }

  /// A new id without a new token (Laravel's `migrate`).
  Future<void> migrate({bool destroy = false}) async {
    if (destroy) {
      await handler.destroy(_id);
    }
    _id = generateId();
  }

  /// Empties the session and gives it a new id (logout).
  Future<void> invalidate() async {
    flush();
    await migrate(destroy: true);
    _format = serialization;
  }

  /// Flashes validation [messages] under [bag]. A PHP session gets Laravel's
  /// `ViewErrorBag`: `ShareErrorsFromSession` passes on anything truthy, so
  /// an array would fail with `getBags() on array` on a page Laravel renders.
  void flashErrors(
    Map<String, List<String>> messages, {
    String bag = 'default',
  }) {
    flash(
      'errors',
      _format == 'php'
          ? PhpObject(r'Illuminate\Support\ViewErrorBag', {
              '\x00*\x00bags': {
                bag: PhpObject(r'Illuminate\Support\MessageBag', {
                  '\x00*\x00messages': messages,
                  '\x00*\x00format': ':message',
                }),
              },
            })
          // `Store::prepareErrorBagForSerialization`: `marshalErrors` reads
          // these two keys back on Laravel 13.
          : {
              bag: {'format': ':message', 'messages': messages},
            },
    );
  }

  /// The validation errors a failed request flashed, by field, whichever
  /// application flashed them.
  Map<String, Object?> get errors {
    var bag = get<Object>('errors');
    if (bag is PhpObject) {
      final bags = bag.properties['\x00*\x00bags'];
      final messages = bags is Map ? bags['default'] : null;
      bag = messages is PhpObject
          ? messages.properties['\x00*\x00messages']
          : null;
    } else if (bag is Map) {
      final entry = bag['default'];
      bag = entry is Map ? entry['messages'] ?? entry : entry;
    }
    return bag is Map
        ? {for (final MapEntry(:key, :value) in bag.entries) '$key': value}
        : const {};
  }

  /// `old('name')`: the input of the failed request.
  T? old<T>(String key, [T? fallback]) {
    final input = get<Object>('_old_input');
    final value = input is Map ? input[key] : null;
    return value is T ? value : fallback;
  }

  String? get previousUrl => get<String>('_previous.url');

  set previousUrl(String? url) => put('_previous.url', url);

  // -- Dot-notation storage ---------------------------------------------------
  //
  // `_flash.new` is stored as PHP does: `['_flash' => ['new' => [...]]]`.

  Object? _get(String key) => _lookup(key).$2;

  (bool, Object?) _lookup(String key) {
    Object? node = _attributes;
    for (final part in key.split('.')) {
      if (node is! Map || !node.containsKey(part)) {
        return (false, null);
      }
      node = node[part];
    }
    return (true, node);
  }

  void _set(String key, Object? value) {
    final parts = key.split('.');
    Map<Object?, Object?> node = _attributes;
    for (final part in parts.take(parts.length - 1)) {
      final child = node[part];
      if (child is Map<Object?, Object?>) {
        node = child;
      } else {
        final created = <String, Object?>{};
        node[part] = created;
        node = created;
      }
    }
    node[parts.last] = value;
  }

  void _remove(String key) {
    final parts = key.split('.');
    Map<Object?, Object?> node = _attributes;
    for (final part in parts.take(parts.length - 1)) {
      final child = node[part];
      if (child is! Map<Object?, Object?>) {
        return;
      }
      node = child;
    }
    node.remove(parts.last);
  }
}

/// `request.session`: the session started by `StartSessionMiddleware`.
extension RequestSession on Request {
  /// The request's session; throws [StateError] when no session middleware
  /// ran for this route.
  Session get session {
    final session = attributes[sessionAttribute];
    if (session is Session) {
      return session;
    }
    throw StateError(
      'No session on this request: put StartSessionMiddleware (the '
      "'session' alias or the 'web' group) on the route.",
    );
  }

  /// The session, or `null` when none was started.
  Session? get sessionOrNull => attributes[sessionAttribute] as Session?;

  /// Key of the session in [Request.attributes].
  static const String sessionAttribute = 'session';
}
