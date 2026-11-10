import 'dart:io';

import 'package:daravel/daravel.dart';

import '../bootstrap/app.dart';

/// HTTP server: `dart run bin/server.dart`. The WebSocket server runs apart:
/// `dart run bin/dartisan.dart reverb:start`.
Future<void> main(List<String> args) async {
  exitCode = await Application.serveWith(createApp);
}
