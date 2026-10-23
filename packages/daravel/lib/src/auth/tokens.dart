import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../database/database_manager.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/container.dart';
import '../http/request.dart';
import 'contracts.dart';
import 'hashing.dart';

/// Extracts the `Authorization: Bearer <token>` value, if any.
String? bearerTokenOf(Request request) {
  final header = request.headers['authorization'];
  if (header == null) {
    return null;
  }
  final match = RegExp(
    r'^\s*Bearer\s+(.+?)\s*$',
    caseSensitive: false,
  ).firstMatch(header);
  return match?.group(1);
}

/// A row of `personal_access_tokens` (Sanctum-compatible schema).
final class PersonalAccessToken {
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

  factory PersonalAccessToken.fromRow(Map<String, Object?> row) {
    final rawAbilities = row['abilities'];
    final abilities = switch (rawAbilities) {
      String() when rawAbilities.isNotEmpty =>
        (jsonDecode(rawAbilities) as List<Object?>).cast<String>(),
      List<Object?>() => rawAbilities.cast<String>(),
      _ => const <String>['*'],
    };
    return PersonalAccessToken(
      id: row['id']!,
      tokenableType: row['tokenable_type'] as String,
      tokenableId: row['tokenable_id']!,
      name: row['name'] as String,
      tokenHash: row['token'] as String,
      abilities: abilities,
      lastUsedAt: parseDbDateTime(row['last_used_at']),
      expiresAt: parseDbDateTime(row['expires_at']),
      createdAt: parseDbDateTime(row['created_at']),
    );
  }

  final Object id;
  final String tokenableType;
  final Object tokenableId;
  final String name;

  /// SHA-256 (hex) of the secret part of the plain-text token.
  final String tokenHash;
  final List<String> abilities;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  /// Whether the token grants [ability] (`*` grants everything).
  bool can(String ability) =>
      abilities.contains('*') || abilities.contains(ability);

  bool cant(String ability) => !can(ability);

  bool isExpired([DateTime? now]) {
    final at = expiresAt;
    return at != null && !at.isAfter(now ?? DateTime.now().toUtc());
  }

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
  const NewAccessToken(this.accessToken, this.plainTextToken);

  final PersonalAccessToken accessToken;

  /// `<id>|<secret>` — send as `Authorization: Bearer`.
  final String plainTextToken;

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
  TokenGuard({
    required super.name,
    required UserProvider<T> provider,
    this.table = 'personal_access_tokens',
    this.expiration,
    this.lastUsedDebounce = const Duration(minutes: 1),
    DatabaseManager? db,
    DateTime Function()? clock,
  }) : _db = db,
       _clock = clock ?? _utcNow,
       super(provider: provider);

  final String table;

  /// Global lifetime measured from `created_at` (Sanctum `expiration`);
  /// `null` means tokens live until revoked unless they carry `expires_at`.
  final Duration? expiration;

  /// Minimum interval between `last_used_at` writes for one token.
  final Duration lastUsedDebounce;

  final DatabaseManager? _db;
  final DateTime Function() _clock;

  UserProvider<T> get users => provider!;

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
    final id = int.tryParse(plainText.substring(0, separator));
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
    final secret = secureRandomString(40);
    final now = _clock();
    final effectiveExpiry =
        expiresAt ?? (expiration == null ? null : now.add(expiration!));
    final hash = _hash(secret);
    final id = await _query().insertGetId(<String, Object?>{
      'tokenable_type': users.morphClass,
      'tokenable_id': user.authIdentifier,
      'name': name,
      'token': hash,
      'abilities': jsonEncode(abilities),
      'expires_at': effectiveExpiry,
      'created_at': now,
      'updated_at': now,
    });
    final token = PersonalAccessToken(
      id: id!,
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

  static DateTime _utcNow() => DateTime.now().toUtc();
}

/// Parses a timestamp column value (driver-specific: `DateTime`, ISO string
/// or epoch milliseconds).
DateTime? parseDbDateTime(Object? value) => switch (value) {
  null => null,
  DateTime() => value.toUtc(),
  int() => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
  String() when value.isEmpty => null,
  String() => DateTime.tryParse(value)?.toUtc(),
  _ => null,
};

/// Creates `personal_access_tokens` with the exact Sanctum schema. Named
/// like Sanctum's migration so a shared `migrations` table stays consistent.
final class CreatePersonalAccessTokensTable extends Migration {
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
