import 'package:daravel/daravel.dart';

/// Smoke-test endpoint used by the walking skeleton.
final class PingController {
  /// `GET /api/ping`
  Future<Object?> ping(Request request) async => <String, Object?>{
    'message': 'pong',
    'app': Config.get<String>('app.name'),
    'request_id': request.id,
    'timestamp': DateTime.now().toUtc(),
  };
}
