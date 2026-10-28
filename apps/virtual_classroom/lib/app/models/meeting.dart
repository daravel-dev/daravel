import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';

import 'classroom.dart';
import 'user.dart';

/// A scheduled lesson in a classroom, held in a LiveKit room. Students see
/// it once it is `published`; its changes go to the activity log.
final class Meeting extends Model with LogsActivity {
  static final ModelDefinition<Meeting> definition = ModelDefinition<Meeting>(
    table: 'meetings',
    factory: Meeting.new,
    fillable: [
      'uuid',
      'classroom_id',
      'created_by',
      'name',
      'description',
      'starts_at',
      'ends_at',
      'room_name',
      'max_participants',
      'status',
      'calendar_event_id',
    ],
    casts: {'starts_at': Cast.dateTime, 'ends_at': Cast.dateTime},
    relations: {
      'classroom': () => BelongsTo<Classroom>(
        () => Classroom.definition,
        foreignKey: 'classroom_id',
      ),
      'creator': () =>
          BelongsTo<User>(() => User.definition, foreignKey: 'created_by'),
    },
    observers: [ActivityLogObserver<Meeting>()],
  );

  @override
  ModelDefinition<Meeting> get modelDefinition => Meeting.definition;

  @override
  LogOptions get activitylogOptions => LogOptions.defaults()
      .logOnly(['name', 'starts_at', 'ends_at', 'status'])
      .logOnlyDirty()
      .useLogName('meetings');

  static ModelQuery<Meeting> query() => definition.query();

  /// How long before the start students may join, and how long after the
  /// end a token stays valid.
  static const Duration earlyJoin = Duration(minutes: 15);
  static const Duration grace = Duration(minutes: 15);

  int get id => getAttr<num>('id').toInt();
  String get uuid => getAttr('uuid');
  int get classroomId => getAttr<num>('classroom_id').toInt();
  String get name => getAttr('name');
  String? get description => getAttr('description');
  DateTime get startsAt => getAttr('starts_at');
  DateTime get endsAt => getAttr('ends_at');
  String get roomName => getAttr('room_name');
  int get maxParticipants => getAttr<num>('max_participants').toInt();
  String get status => getAttr('status');
  String? get calendarEventId => getAttr('calendar_event_id');

  bool get isPublished => status == 'published';

  Future<Classroom> classroom() async =>
      (await Classroom.query().find(classroomId))!;

  /// Whether the room is open at [now]: from [earlyJoin] before the start
  /// to the end.
  bool isOpenAt(DateTime now) =>
      !now.isBefore(startsAt.subtract(earlyJoin)) && now.isBefore(endsAt);
}
