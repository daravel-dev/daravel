import 'package:daravel/daravel.dart';
import 'package:daravel_starter/app/http/requests/store_user_request.dart';

/// Users API (plain SQL until the ORM lands in slice S6).
final class UserController {
  /// `GET /api/users/{id}`
  Future<Object?> show(Request request) async {
    final id = request.param<int>('id');
    final rows = await DB.select(
      'SELECT "id", "name", "email", "created_at" FROM "users" WHERE "id" = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) {
      abort(404, 'User [$id] not found.');
    }
    return <String, Object?>{'data': rows.first};
  }

  /// `POST /api/users`
  Future<Object?> store(Request request) async {
    final data = await FormRequest.run(const StoreUserRequest(), request);
    final now = DateTime.now().toUtc().toIso8601String();
    final id = await DB.transaction(
      () => DB.insertGetId(
        'INSERT INTO "users" ("name", "email", "password", "created_at", "updated_at") '
        'VALUES (?, ?, ?, ?, ?)',
        <Object?>[
          data.string('name'),
          data.string('email'),
          // Hashing arrives with the auth slice (S8); never store plain text in real apps.
          'plain:${data.string('password')}',
          now,
          now,
        ],
      ),
    );
    return Response.created(<String, Object?>{
      'data': <String, Object?>{
        'id': id,
        'name': data.string('name'),
        'email': data.string('email'),
        'created_at': now,
      },
    });
  }
}
