import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';

import '../../models/classroom.dart';
import '../../models/meeting.dart';
import '../../models/user.dart';

/// Provides demo state, switcher profiles, activity logs, and calendar preview.
final class DemoController {
  const DemoController();

  /// `GET /api/demo/state`
  Future<Object?> state(Request request) async {
    // Ensure an outsider exists for testing authorization failures
    final existingOutsider = await User.query()
        .where('email', 'outsider@example.com')
        .first();
    if (existingOutsider == null) {
      final pwd = await Hash.make('password');
      final out = await User.query().create({
        'name': 'Outsider (Siswa Luar Kelas)',
        'email': 'outsider@example.com',
        'password': pwd,
      });
      await out.assignRole('student');
    }

    final users = await User.query().orderBy('id').get();
    final userList = <Map<String, Object?>>[];
    for (final u in users) {
      final isTeacher = await u.isTeacher;
      userList.add({
        'id': u.id,
        'name': u.name,
        'email': u.email,
        'role': isTeacher ? 'teacher' : 'student',
      });
    }

    final classrooms = await Classroom.query().orderBy('id').get();
    final classroomList = <Map<String, Object?>>[];
    for (final c in classrooms) {
      final emails = await c.studentEmails();
      classroomList.add({
        'id': c.id,
        'name': c.name,
        'teacher_id': c.teacherId,
        'students_count': emails.length,
        'student_emails': emails,
      });
    }

    // Recent activity logs from daravel_activitylog
    List<Map<String, Object?>> activities = [];
    try {
      final logs = await Activity.query()
          .orderBy('created_at', 'desc')
          .limit(25)
          .get();
      activities = [
        for (final act in logs)
          {
            'id': act.id,
            'log_name': act.logName,
            'description': act.description,
            'event': act.event,
            'subject_type': act.subjectType,
            'subject_id': act.subjectId,
            'causer_id': act.causerId,
            'properties': act.properties,
            'created_at': act.createdAt?.toIso8601String(),
          },
      ];
    } catch (e) {
      Log.warning('ActivityLog query failed or empty: $e');
    }

    // Google Calendar preview: meetings that are published
    final publishedMeetings = await Meeting.query()
        .where('status', 'published')
        .orderBy('starts_at')
        .get();

    final calendarEvents = <Map<String, Object?>>[];
    for (final m in publishedMeetings) {
      final c = await m.classroom();
      calendarEvents.add({
        'meeting_id': m.id,
        'uuid': m.uuid,
        'summary': '${c.name}: ${m.name}',
        'description': m.description,
        'starts_at': m.startsAt.toIso8601String(),
        'ends_at': m.endsAt.toIso8601String(),
        'event_id': m.calendarEventId ?? 'simulated-evt-${m.id}',
        'attendees': await c.studentEmails(),
        'status': 'confirmed',
      });
    }

    return {
      'server_now': Clock.now().toUtc().toIso8601String(),
      'users': userList,
      'classrooms': classroomList,
      'calendar_events': calendarEvents,
      'recent_activities': activities,
    };
  }

  /// `GET /api/activity-logs`
  Future<Object?> activityLogs(Request request) async {
    final logs = await Activity.query()
        .orderBy('created_at', 'desc')
        .limit(50)
        .get();
    return [
      for (final act in logs)
        {
          'id': act.id,
          'log_name': act.logName,
          'description': act.description,
          'event': act.event,
          'subject_type': act.subjectType,
          'subject_id': act.subjectId,
          'causer_id': act.causerId,
          'properties': act.properties,
          'created_at': act.createdAt?.toIso8601String(),
        },
    ];
  }
}
