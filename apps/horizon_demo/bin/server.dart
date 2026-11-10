import 'dart:io';

import 'package:daravel/daravel.dart';

import '../bootstrap/app.dart';

/// HTTP server: `dart run bin/server.dart`. With `SERVER_EMBED_WORKERS=horizon`
/// (or `dartisan serve --embed-worker=horizon`) Horizon's supervisors run in
/// the same process.
Future<void> main(List<String> args) async {
  exitCode = await Application.serveWith(createApp);
}
