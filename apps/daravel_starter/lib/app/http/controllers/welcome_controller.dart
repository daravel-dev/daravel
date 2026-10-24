import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_starter/resources/views/welcome_page.dart';

/// Serves the welcome landing page at `/` (Laravel's `welcome.blade.php`).
final class WelcomeController {
  static const String frameworkVersion = daravelVersion;

  Future<Object?> index(Request request) async {
    final app = Config.section<AppConfig>();
    return Response.html(
      welcomePage(
        appName: app.name,
        environment: app.env,
        dartVersion: Platform.version.split(' ').first,
        frameworkVersion: frameworkVersion,
        requestId: request.id,
      ),
    );
  }
}
