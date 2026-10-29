import 'package:daravel/daravel.dart';

/// Laravel's `sessions` table (laravel/laravel
/// `0001_01_01_000000_create_users_table`, which creates it next to
/// `users`): `id`, `user_id`, `ip_address`, `user_agent`, `payload`,
/// `last_activity`. It creates nothing when the table exists already,
/// since a Laravel application's own migration then owns it.
final class CreateSessionsTable extends Migration {
  const CreateSessionsTable();

  @override
  String get name => '2026_10_29_000000_create_sessions_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    if (await schema.hasTable('sessions')) {
      return;
    }
    await schema.create('sessions', (table) {
      table.string('id').primary();
      table.unsignedBigInteger('user_id').nullable().index();
      table.string('ip_address', length: 45).nullable();
      table.text('user_agent').nullable();
      table.longText('payload');
      table.integer('last_activity').index();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('sessions');
}
