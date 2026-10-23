import '../bootstrap/app.dart';

/// HTTP server entrypoint (`dart run bin/server.dart` or the AOT binary).
Future<void> main(List<String> args) async {
  final app = createApp();
  await app.boot();
  await app.serve();
}
