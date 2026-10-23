import 'package:daravel/daravel.dart';

/// Smoke-test endpoints used by the walking skeleton.
final class PingController {
  /// `GET /api/ping`
  Future<Object?> ping(Request request) async => <String, Object?>{
    'message': 'pong',
    'app': Config.get<String>('app.name'),
    'request_id': request.id,
    'timestamp': DateTime.now().toUtc(),
  };

  /// `GET /api/users/{id}` — demonstrates typed route parameters.
  Future<Object?> showUser(Request request) async {
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
}
