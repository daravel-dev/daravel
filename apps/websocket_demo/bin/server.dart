import 'dart:io';

import 'package:daravel/daravel.dart';

import '../bootstrap/app.dart';

/// HTTP and WebSocket server entrypoint: `dart run bin/server.dart`.
Future<void> main(List<String> args) async {
  exitCode = await Application.serveWith(createApp);
}
