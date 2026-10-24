import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_starter/resources/views/welcome_page.dart';

/// Serves the welcome landing page at `/` (Laravel's `welcome.blade.php`).
///
/// Browsers get the HTML page; clients asking for JSON (`Accept:
/// application/json`) get a short status document instead.
final class WelcomeController {
  static const String frameworkVersion = daravelVersion;

  Future<Object?> index(Request request) async {
    final app = Config.section<AppConfig>();
    if (request.expectsJson) {
      return <String, Object?>{
        'app': app.name,
        'env': app.env,
        'daravel': frameworkVersion,
      };
    }
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
