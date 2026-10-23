import 'package:daravel/daravel.dart';

import '../factories/user_factory.dart';

/// Root seeder run by `dartisan db:seed` (Laravel's `DatabaseSeeder`).
final class DatabaseSeeder extends Seeder {
  const DatabaseSeeder();

  @override
  Future<void> run() async {
    // Every seeded user logs in with "password".
    final password = await Hash.make('password');
    await userFactory(
      passwordHash: password,
    ).createMany(const <String, Object?>{}, 10);
    await userFactory(
      passwordHash: password,
    ).create({'name': 'Test User', 'email': 'test@example.com'});
  }
}
