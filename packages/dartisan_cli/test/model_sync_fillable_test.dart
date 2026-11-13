import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:test/test.dart';

final class _Any extends Model {
  @override
  ModelDefinition<_Any> get modelDefinition => throw UnimplementedError();
}

/// `model:sync` writes `createWith`/`fillWith` parameters only for the
/// columns `fill` keeps, so `ModelSource.isFillable` must decide as
/// `ModelDefinition.isFillable` does for every list and key.
void main() {
  test('ModelSource.isFillable agrees with ModelDefinition.isFillable', () {
    const lists = <(List<String>, List<String>)>[
      ([], ['*']),
      ([], []),
      ([], ['role', 'meta']),
      ([], ['Role']),
      (['name', 'meta'], ['*']),
      (['name'], ['role']),
    ];
    final keys = [
      'name',
      'role',
      'ROLE',
      'Role',
      'role ',
      ' role',
      'users.role',
      'meta->role',
      'meta',
      '_token',
      '_x',
      'a1',
      '1a',
      'r${String.fromCharCode(0x043e)}le',
      '',
    ];
    for (final (fillable, guarded) in lists) {
      final definition = ModelDefinition<_Any>(
        table: 'users',
        factory: _Any.new,
        fillable: fillable,
        guarded: guarded,
      );
      final source = ModelSource(
        className: 'User',
        table: 'users',
        casts: const {},
        primaryKey: 'id',
        authenticatable: false,
        fillable: fillable,
        guarded: guarded,
      );
      for (final key in keys) {
        expect(
          source.isFillable(key),
          definition.isFillable(key),
          reason: 'fillable $fillable, guarded $guarded, key "$key"',
        );
      }
    }
  });
}
