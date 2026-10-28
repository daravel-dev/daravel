import 'package:daravel/daravel.dart';
import 'package:daravel_teorion/daravel_teorion.dart';

import '../../filters/meeting_query_filter.dart';
import '../../jobs/sync_meeting_calendar.dart';
import '../../models/classroom.dart';
import '../../models/meeting.dart';
import '../../models/user.dart';
import '../../policies/meeting_policy.dart';
import '../../services/classroom_room.dart';
import '../resources/meeting_resource.dart';

/// Meetings of the classrooms the user teaches or attends.
final class MeetingController {
  const MeetingController();

  static const Map<String, Object> rules = {
    'name': 'required|string|max:150',
    'description': 'nullable|string|max:2000',
    'starts_at': 'required|date',
    'ends_at': 'required|date|after:starts_at',
    'max_participants': 'integer|min:2|max:500',
    'status': 'in:draft,published',
  };

  /// `GET /api/meetings`: the user's classrooms only; students see the
  /// published meetings. Filters, sorts and pages with `daravel_teorion`.
  Future<Object?> index(Request request) async {
    final user = (await request.user<User>())!;
    final classrooms = await Classroom.idsOf(user);
    final taught = [
      for (final row
          in await Classroom.query().where('teacher_id', user.id).get())
        row.id,
    ];
    final query = Meeting.query()
        .whereIn('classroom_id', classrooms.isEmpty ? [0] : classrooms)
        .where((QueryBuilder q) {
          q.where('status', 'published');
          if (taught.isNotEmpty) {
            q.orWhereIn('classroom_id', taught);
          }
        });
    // A list, or a page with `?is_paginate=1` (data, links, meta).
    return JsonResource.collection(
      await query.filterAndPaginate(request, const MeetingQueryFilter()),
      MeetingResource.new,
    );
  }

  /// `POST /api/classrooms/{classroom}/meetings`: the classroom's teacher
  /// schedules a meeting; a published one is put in the calendar.
  Future<Object?> store(Request request) async {
    final user = (await request.user<User>())!;
    final classroom = await Classroom.query().findOrFail(
      request.param<int>('classroom'),
    );
    if (!await MeetingPolicy.canCreateIn(user, classroom)) {
      abort(403, 'Only the teacher of this classroom may schedule meetings.');
    }
    final data = await request.validate(rules);
    final meeting = await DB.transaction(() async {
      final uuid = Str.uuid();
      final meeting = await Meeting.query().create({
        'uuid': uuid,
        'classroom_id': classroom.id,
        'created_by': user.id,
        'name': data.string('name'),
        'description': data.maybeString('description'),
        'starts_at': data.dateTime('starts_at'),
        'ends_at': data.dateTime('ends_at'),
        'room_name': 'meeting-$uuid',
        'max_participants': data.maybeInteger('max_participants') ?? 50,
        'status': data.maybeString('status') ?? 'draft',
      });
      // Queued after the commit: a rollback queues nothing.
      await Queue.dispatch(SyncMeetingCalendar(meeting.id));
      return meeting;
    });
    // 201: the model was just created.
    return MeetingResource(meeting);
  }

  /// `GET /api/meetings/{meeting}`
  Future<Object?> show(Request request) async {
    final meeting = await _find(request);
    await request.authorize('view', [meeting]);
    return MeetingResource(meeting);
  }

  /// `PATCH /api/meetings/{meeting}`: the teacher reschedules, publishes or
  /// unpublishes; the calendar follows.
  Future<Object?> update(Request request) async {
    final meeting = await _find(request);
    await request.authorize('update', [meeting]);
    final data = await request.validate({
      for (final MapEntry(:key, :value) in rules.entries)
        key: 'sometimes|${(value as String).replaceFirst('required|', '')}',
    });
    await DB.transaction(() async {
      await meeting.update({
        for (final key in rules.keys)
          if (data.has(key))
            key: key.endsWith('_at') ? data.dateTime(key) : data.get(key),
      });
      await Queue.dispatch(SyncMeetingCalendar(meeting.id));
    });
    return MeetingResource(meeting);
  }

  /// `DELETE /api/meetings/{meeting}`: its calendar event goes too.
  Future<Object?> destroy(Request request) async {
    final meeting = await _find(request);
    await request.authorize('delete', [meeting]);
    await DB.transaction(() async {
      await meeting.delete();
      await Queue.dispatch(
        SyncMeetingCalendar(meeting.id, eventId: meeting.calendarEventId),
      );
    });
    return Response.noContent();
  }

  /// `POST /api/meetings/{meeting}/join`: a LiveKit token for the room,
  /// from 15 minutes before the start to the end.
  Future<Object?> join(Request request) async {
    final meeting = await _find(request);
    await request.authorize('view', [meeting]);
    if (!meeting.isOpenAt(Clock.now())) {
      abort(
        409,
        'The room opens 15 minutes before the meeting starts and closes '
        'when it ends.',
      );
    }
    final pass = await ClassroomRoom.pass(
      meeting,
      (await request.user<User>())!,
    );
    return pass.toJson();
  }

  static Future<Meeting> _find(Request request) => Meeting.query()
      .where('uuid', request.param<String>('meeting'))
      .firstOrFail();
}
