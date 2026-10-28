import 'package:daravel_google/daravel_google.dart';

void main() {
  final now = DateTime.now();
  final event = CalendarEvent(
    summary: 'Team Sync on Daravel Architecture',
    description:
        'Discussing the 160/160 pub points quality blueprint and roadmap.',
    start: EventTime(now.add(const Duration(hours: 1))),
    end: EventTime(now.add(const Duration(hours: 2))),
    attendees: [
      const EventAttendee('lead@daravel.dev', displayName: 'Lead Maintainer'),
      const EventAttendee('dev@daravel.dev', displayName: 'Core Contributor'),
    ],
    meet: true,
  );

  print('Prepared Google Calendar event: ${event.summary}');
  print('Start time: ${event.start?.dateTime}');
  print('Attendees: ${event.attendees?.map((a) => a.email).join(', ')}');
}
