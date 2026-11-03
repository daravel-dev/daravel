import 'dart:io';

import 'package:daravel/daravel.dart';

import '../../../resources/views/virtual_classroom_page.dart';

/// Web Controller serving the interactive Virtual Classroom client at `/`.
final class ClassroomWebController {
  const ClassroomWebController();

  Future<Response> index(Request request) async {
    // Returns JSON if client explicitly requests JSON without HTML
    final accept = request.header('accept') ?? '';
    if (accept.contains('application/json') &&
        !accept.contains('text/html') &&
        !request.acceptsHtml) {
      return Response.json({
        'app': 'Virtual Classroom',
        'framework': 'Daravel',
        'version': daravelVersion,
        'description': 'Scheduled Lessons, LiveKit WebRTC Rooms & Google Calendar Integration',
      });
    }

    return Response.html(
      virtualClassroomPage(
        appName: Config.section<AppConfig>().name,
        environment: Config.section<AppConfig>().env,
        dartVersion: Platform.version.split(' ').first,
        frameworkVersion: daravelVersion,
        requestId: request.id,
      ),
    );
  }
}
