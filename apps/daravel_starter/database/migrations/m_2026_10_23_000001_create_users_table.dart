import 'package:daravel/daravel.dart';

/// Creates the `users` table (Laravel default columns).
final class CreateUsersTable extends Migration {
  const CreateUsersTable();

  @override
  String get name => '2026_10_23_000001_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.timestamp('email_verified_at').nullable();
    table.string('password');
    table.string('remember_token', length: 100).nullable();
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}
