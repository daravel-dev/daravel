// Job registry: the queued jobs a worker can rebuild.
import 'package:daravel/daravel.dart';
import 'package:virtual_classroom/app/jobs/sync_meeting_calendar.dart';

final List<JobDefinition> jobs = <JobDefinition>[
  // <dartisan:entries>
  SyncMeetingCalendar.definition,
  // </dartisan:entries>
];
