import 'dart:io';

import 'package:cat_exam_demo/resources/views/cat_exam_page.dart';
import 'package:daravel/daravel.dart';

/// Web Controller serving the interactive CAT examination client at `/`.
final class ExamWebController {
  Future<Response> index(Request request) async {
    final app = Config.section<AppConfig>();

    // Returns JSON only when explicitly requested without HTML support
    final accept = request.header('accept') ?? '';
    if (accept.contains('application/json') &&
        !accept.contains('text/html') &&
        !request.acceptsHtml) {
      return Response.json({
        'app': app.name,
        'environment': app.env,
        'daravel': daravelVersion,
        'description': 'CAT CPNS / TKA High-Scale Examination Platform',
      });
    }

    return Response.html(
      catExamPage(
        appName: app.name,
        environment: app.env,
        dartVersion: Platform.version.split(' ').first,
        frameworkVersion: daravelVersion,
        requestId: request.id,
      ),
    );
  }
}
