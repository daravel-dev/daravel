import 'dart:io';

import 'package:daravel/daravel.dart';

import '../bootstrap/app.dart';

/// HTTP server entrypoint (`dart run bin/server.dart` or the AOT binary).
Future<void> main(List<String> args) async {
  exitCode = await Application.serveWith(createApp);
}
