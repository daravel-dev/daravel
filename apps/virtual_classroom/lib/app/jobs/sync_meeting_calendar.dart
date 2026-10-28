import 'package:daravel/daravel.dart';
import 'package:daravel_google/daravel_google.dart';

import '../models/meeting.dart';

/// Puts a published meeting in the school's Google Calendar with the
/// classroom's students as guests, keeps it up to date, and removes it
/// when the meeting is unpublished or deleted.
///
/// Runs on the queue, after the transaction that changed the meeting
/// commits; it does nothing until `GOOGLE_APPLICATION_CREDENTIALS` names a
/// service account with access to `GOOGLE_CALENDAR_ID`.
final class SyncMeetingCalendar extends Job {
  SyncMeetingCalendar(this.meetingId, {this.eventId});

  factory SyncMeetingCalendar.fromJson(Map<String, Object?> json) =>
      SyncMeetingCalendar(
        (json['meeting_id']! as num).toInt(),
        eventId: json['event_id'] as String?,
      );

  static const JobDefinition definition = JobDefinition(
    'sync-meeting-calendar',
    SyncMeetingCalendar.fromJson,
  );

  final int meetingId;

  /// The event of a meeting deleted since; it is removed.
  final String? eventId;

  @override
  String get jobName => definition.name;

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [Duration(seconds: 30)];

  @override
  Map<String, Object?> toJson() => {
    'meeting_id': meetingId,
    'event_id': ?eventId,
  };

  @override
  Future<void> handle(JobContext ctx) async {
    if ((Google.config.credentials ?? '').isEmpty) {
      return;
    }
    final calendar = Google.serviceCalendar();
    final meeting = await Meeting.query().find(meetingId);
    final existing = meeting?.calendarEventId ?? eventId;
    if (meeting == null || !meeting.isPublished) {
      if (existing != null) {
        await calendar.delete(existing);
      }
      if (meeting != null && meeting.calendarEventId != null) {
        await meeting.update({'calendar_event_id': null});
      }
      return;
    }
    final classroom = await meeting.classroom();
    final event = CalendarEvent(
      summary: '${classroom.name}: ${meeting.name}',
      description: meeting.description,
      start: EventTime(meeting.startsAt.toUtc()),
      end: EventTime(meeting.endsAt.toUtc()),
      attendees: [
        for (final email in await classroom.studentEmails())
          EventAttendee(email),
      ],
    );
    if (existing == null) {
      final created = await calendar.create(event);
      await meeting.update({'calendar_event_id': created.id});
    } else {
      await calendar.patch(existing, event);
    }
  }
}
