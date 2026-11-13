import 'dart:convert';
import 'dart:typed_data';

import '../foundation/clock.dart';

import 'package:crypto/crypto.dart' as crypto;

import '../database/database_manager.dart';
import '../database/orm/casts.dart';
import '../database/orm/keys.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/container.dart';
import '../http/request.dart';
import 'bearer.dart';
import 'contracts.dart';
import 'hashing.dart';

/// Extracts the `Authorization: Bearer <token>` value, if any.
String? bearerTokenOf(Request request) {
  final header = request.headers['authorization'];
  return header == null ? null : bearerTokenFromHeader(header);
}

/// A row of `personal_access_tokens` (Sanctum-compatible schema).
final class PersonalAccessToken {
  /// A personal access token row.
  const PersonalAccessToken({
    required this.id,
    required this.tokenableType,
    required this.tokenableId,
    required this.name,
    required this.tokenHash,
    required this.abilities,
    this.lastUsedAt,
    this.expiresAt,
    this.createdAt,
  });

  /// The token in a `personal_access_tokens` row.
  factory PersonalAccessToken.fromRow(Map<String, Object?> row) {
    return PersonalAccessToken(
      id: row['id']!,
      tokenableType: row['tokenable_type'] as String? ?? '',
      tokenableId: row['tokenable_id'] ?? '',
      name: row['name'] as String? ?? '',
      // No hash matches no secret.
      tokenHash: row['token'] as String? ?? '',
      abilities: abilitiesOf(row['abilities']),
      lastUsedAt: parseDbDateTime(row['last_used_at']),
      expiresAt: parseDbDateTime(row['expires_at']),
      createdAt: parseDbDateTime(row['created_at']),
    );
  }

  /// The abilities in a token row's `abilities` column, failing closed: a
  /// JSON list of strings as Daravel and Sanctum write it (`["*"]` for a
  /// token with every ability); anything else (`NULL`, empty, not JSON,
  /// not a list) is none at all, and elements that are not strings are
  /// left out. Before, `NULL` or an empty value read as `["*"]`. Sanctum
  /// throws on `NULL`; neither ever writes it.
  static List<String> abilitiesOf(Object? raw) {
    final text = switch (raw) {
      final String s => s,
      final Uint8List bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    Object? decoded = raw is List<Object?> && raw is! Uint8List ? raw : null;
    if (text != null && text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
    }
    return decoded is List
        ? List<String>.unmodifiable([
            for (final ability in decoded)
              if (ability is String) ability,
          ])
        : const <String>[];
  }

  /// The row id, the number before `|` in the plain text token.
  final Object id;

  /// The morph class of the token's owner.
  final String tokenableType;

  /// The owner's key.
  final Object tokenableId;

  /// The name the token was created with.
  final String name;

  /// SHA-256 (hex) of the secret part of the plain-text token.
  final String tokenHash;

  /// The abilities granted; `*` for every one.
  final List<String> abilities;

  /// When the token was last used.
  final DateTime? lastUsedAt;

  /// When the token expires; null for never.
  final DateTime? expiresAt;

  /// When the token was created.
  final DateTime? createdAt;

  /// Whether the token grants [ability] (`*` grants everything).
  bool can(String ability) =>
      abilities.contains('*') || abilities.contains(ability);

  /// Whether the token lacks [ability].
  bool cant(String ability) => !can(ability);

  /// Whether the token has expired at [now] (`Clock.now()`).
  bool isExpired([DateTime? now]) {
    final at = expiresAt;
    return at != null && !at.isAfter(now ?? Clock.now().toUtc());
  }

  /// The token as JSON, without its hash.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'abilities': abilities,
    'last_used_at': lastUsedAt?.toIso8601String(),
    'expires_at': expiresAt?.toIso8601String(),
    'created_at': createdAt?.toIso8601String(),
  };
}

/// Result of [TokenGuard.issue]: the plain-text token is only available
/// here, never again (only its hash is stored).
final class NewAccessToken {
  /// A new [accessToken] and its [plainTextToken], shown once.
  const NewAccessToken(this.accessToken, this.plainTextToken);

  /// The stored token.
  final PersonalAccessToken accessToken;

  /// `<id>|<secret>` — send as `Authorization: Bearer`.
  final String plainTextToken;

  /// The token as JSON, the plain text included.
  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken.toJson(),
    'plainTextToken': plainTextToken,
  };
}

/// Sanctum-style personal access token guard (BLUEPRINT_V2 §7.6.2).
///
/// Token format `id|secret`: the id gives an O(1) lookup, the secret is
/// compared as `sha256(secret)` in constant time. Tokens issued by a Laravel
/// app sharing the database are accepted and vice versa.
final class TokenGuard<T extends Authenticatable> extends RequestGuard<T> {
  /// A guard reading `Authorization: Bearer <id>|<secret>` tokens from the
  /// table Sanctum uses.
  TokenGuard({
    required super.name,
    required UserProvider<T> provider,
    this.table = 'personal_access_tokens',
    this.expiration,
    this.lastUsedDebounce = const Duration(minutes: 1),
    this.tokenPrefix = '',
    this._db,
    DateTime Function()? clock,
    this.keyType = KeyType.autoInt,
  }) : _clock = clock ?? _utcNow,
       super(provider: provider) {
    if (!_supportedKeyTypes.contains(keyType)) {
      throw ArgumentError.value(
        keyType,
        'keyType',
        'A token table key is KeyType.autoInt (Sanctum\'s default), '
            'KeyType.uuid or KeyType.ulid (a PersonalAccessToken model with '
            'HasUuids or HasUlids)',
      );
    }
  }

  static const Set<KeyType> _supportedKeyTypes = {
    KeyType.autoInt,
    KeyType.uuid,
    KeyType.ulid,
  };

  /// The tokens table (`personal_access_tokens`).
  final String table;

  /// The type of the table's `id`: [KeyType.autoInt] (Sanctum's migration),
  /// or [KeyType.uuid] / [KeyType.ulid] when the application's
  /// `PersonalAccessToken` model uses `HasUuids` / `HasUlids`. It decides
  /// which `<id>|` a token may start with (any other is refused before the
  /// database is asked, so a text id never reaches an integer column) and
  /// how [issue] makes the id of a new token.
  final KeyType keyType;

  /// Global lifetime measured from `created_at` (Sanctum `expiration`);
  /// `null` means tokens live until revoked unless they carry `expires_at`.
  final Duration? expiration;

  /// Minimum interval between `last_used_at` writes for one token.
  final Duration lastUsedDebounce;

  /// Prepended to new secrets (Sanctum `token_prefix`, e.g. `myapp_`).
  final String tokenPrefix;

  final DatabaseManager? _db;
  final DateTime Function() _clock;

  /// The user provider.
  UserProvider<T> get users => provider!;

  /// The database holding the tokens.
  DatabaseManager get db => _db ?? Container.current.make<DatabaseManager>();

  QueryBuilder _query() => db.table(table);

  @override
  Future<T?> resolveUser(Request request) async {
    final bearer = bearerTokenOf(request);
    if (bearer == null || bearer.isEmpty) {
      return null;
    }
    final token = await findToken(bearer);
    if (token == null || !_isValid(token)) {
      return null;
    }
    if (token.tokenableType != users.morphClass) {
      return null;
    }
    final user = await users.retrieveById(token.tokenableId);
    if (user == null) {
      return null;
    }
    AuthScope.state().token = token;
    await _touchLastUsed(token);
    return user;
  }

  /// Finds the token row for a plain-text token (`id|secret` or legacy
  /// secret-only) without checking expiry.
  Future<PersonalAccessToken?> findToken(String plainText) async {
    final separator = plainText.indexOf('|');
    if (separator == -1) {
      final row = await _query().where('token', _hash(plainText)).first();
      return row == null ? null : PersonalAccessToken.fromRow(row);
    }
    final id = _tokenId(plainText.substring(0, separator));
    final secret = plainText.substring(separator + 1);
    if (id == null || secret.isEmpty) {
      return null;
    }
    final row = await _query().where('id', id).first();
    if (row == null) {
      return null;
    }
    final token = PersonalAccessToken.fromRow(row);
    return constantTimeEquals(token.tokenHash, _hash(secret)) ? token : null;
  }

  /// The `<id>` of an `<id>|<secret>` token as the table's key, or null
  /// when it cannot be one: an integer for [KeyType.autoInt], a UUID or a
  /// ULID string for the others (Laravel's `Str::isUuid`/`Str::isUlid`).
  /// Checked before the query, so a text id never goes to an integer
  /// column (which PostgreSQL refuses with an error, not a miss).
  Object? _tokenId(String raw) => switch (keyType) {
    KeyType.uuid => _uuidPattern.hasMatch(raw) ? raw : null,
    KeyType.ulid => _ulidPattern.hasMatch(raw) ? raw : null,
    _ => _intPattern.hasMatch(raw) ? int.tryParse(raw) : null,
  };

  static final RegExp _intPattern = RegExp(r'^[0-9]{1,19}$');
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );
  static final RegExp _ulidPattern = RegExp(
    r'^[0-7][0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]{25}$',
  );

  /// The token used by the current request, if any.
  Future<PersonalAccessToken?> currentAccessToken() async {
    await user();
    return AuthScope.state().token as PersonalAccessToken?;
  }

  /// Whether the current request's token grants [ability].
  Future<bool> tokenCan(String ability) async =>
      (await currentAccessToken())?.can(ability) ?? false;

  /// Issues a token for [user] (`$user->createToken()` in Sanctum).
  Future<NewAccessToken> issue(
    Authenticatable user,
    String name, {
    List<String> abilities = const <String>['*'],
    DateTime? expiresAt,
  }) async {
    // Sanctum 4: prefix + 40 random chars + crc32b(entropy).
    final entropy = secureRandomString(40);
    final secret = '$tokenPrefix$entropy${crc32b(utf8.encode(entropy))}';
    final now = _clock();
    final effectiveExpiry =
        expiresAt ?? (expiration == null ? null : now.add(expiration!));
    final hash = _hash(secret);
    final row = <String, Object?>{
      'tokenable_type': users.morphClass,
      'tokenable_id': user.authIdentifier,
      'name': name,
      'token': hash,
      'abilities': jsonEncode(abilities),
      'expires_at': effectiveExpiry,
      'created_at': now,
      'updated_at': now,
    };
    final Object id;
    switch (keyType) {
      case KeyType.uuid || KeyType.ulid:
        // HasUuids / HasUlids: the key is made before the insert.
        id = keyType == KeyType.uuid
            ? KeyGenerator.uuid()
            : KeyGenerator.ulid(now);
        await _query().insert(<String, Object?>{'id': id, ...row});
      default:
        id = (await _query().insertGetId(row))!;
    }
    final token = PersonalAccessToken(
      id: id,
      tokenableType: users.morphClass,
      tokenableId: user.authIdentifier,
      name: name,
      tokenHash: hash,
      abilities: abilities,
      expiresAt: effectiveExpiry,
      createdAt: now,
    );
    return NewAccessToken(token, '$id|$secret');
  }

  /// Deletes the token used by the current request. Returns rows deleted.
  Future<int> revokeCurrent() async {
    final token = await currentAccessToken();
    if (token == null) {
      return 0;
    }
    final deleted = await _query().where('id', token.id).delete();
    forgetUser();
    return deleted;
  }

  /// Deletes every token of [user].
  Future<int> revokeAll(Authenticatable user) => _ownedBy(user).delete();

  /// Deletes one token of [user] by id.
  Future<int> revoke(Authenticatable user, Object tokenId) =>
      _ownedBy(user).where('id', tokenId).delete();

  /// Lists the tokens of [user] (newest first).
  Future<List<PersonalAccessToken>> tokens(Authenticatable user) async {
    final rows = await _ownedBy(user).orderBy('id', 'desc').get();
    return rows.map(PersonalAccessToken.fromRow).toList();
  }

  /// Deletes tokens expired for longer than [olderThan]
  /// (`sanctum:prune-expired --hours=`).
  Future<int> pruneExpired({Duration olderThan = Duration.zero}) =>
      _query().where('expires_at', '<', _clock().subtract(olderThan)).delete();

  QueryBuilder _ownedBy(Authenticatable user) => _query()
      .where('tokenable_type', users.morphClass)
      .where('tokenable_id', user.authIdentifier);

  bool _isValid(PersonalAccessToken token) {
    final now = _clock();
    if (token.isExpired(now)) {
      return false;
    }
    final lifetime = expiration;
    final created = token.createdAt;
    if (lifetime != null && created != null) {
      return created.add(lifetime).isAfter(now);
    }
    return true;
  }

  Future<void> _touchLastUsed(PersonalAccessToken token) async {
    final now = _clock();
    final last = token.lastUsedAt;
    if (last != null && now.difference(last) < lastUsedDebounce) {
      return;
    }
    await _query().where('id', token.id).update(<String, Object?>{
      'last_used_at': now,
    });
  }

  static String _hash(String secret) =>
      crypto.sha256.convert(utf8.encode(secret)).toString();

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Parses a timestamp column value (driver-specific: `DateTime`, ISO string
/// or epoch milliseconds). Text without a zone, such as MySQL's
/// `Y-m-d H:i:s`, is UTC, the zone the framework writes in, whatever the
/// zone of the process.
DateTime? parseDbDateTime(Object? value) => switch (value) {
  DateTime() => value.toUtc(),
  _ => parseDateTime(value)?.toUtc(),
};

/// Creates `personal_access_tokens` with the exact Sanctum schema. Named
/// like Sanctum's migration so a shared `migrations` table stays consistent.
final class CreatePersonalAccessTokensTable extends Migration {
  /// The migration creating `personal_access_tokens`, as Sanctum's.
  const CreatePersonalAccessTokensTable();

  @override
  String get name => '2019_12_14_000001_create_personal_access_tokens_table';

  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.create('personal_access_tokens', (table) {
        table.id();
        table.string('tokenable_type');
        table.unsignedBigInteger('tokenable_id');
        table.index(const ['tokenable_type', 'tokenable_id']);
        table.text('name');
        table.string('token', length: 64).unique();
        table.text('abilities').nullable();
        table.timestamp('last_used_at').nullable();
        table.timestamp('expires_at').nullable().index();
        table.timestamps();
      });

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists('personal_access_tokens');
}
