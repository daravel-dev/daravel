import 'package:daravel/daravel.dart';

/// Exam session representing an active or completed CAT exam run.
final class ExamSession extends Model {
  static final ModelDefinition<ExamSession> definition =
      ModelDefinition<ExamSession>(
        table: 'exam_sessions',
        factory: ExamSession.new,
        primaryKey: 'id',
        keyType: .string,
        fillable: [
          'id',
          'candidate_id',
          'device_id',
          'token',
          'started_at',
          'duration_minutes',
          'expires_at',
          'submitted_at',
          'status',
          'score_twk',
          'score_tiu',
          'score_tkp',
          'total_score',
          'passing_grade_met',
          'ranking',
          'seed',
        ],
        casts: {
          'candidate_id': Cast.integer,
          'duration_minutes': Cast.integer,
          'score_twk': Cast.integer,
          'score_tiu': Cast.integer,
          'score_tkp': Cast.integer,
          'total_score': Cast.integer,
          'passing_grade_met': Cast.boolean,
          'ranking': Cast.integer,
          'seed': Cast.integer,
          'started_at': Cast.dateTime,
          'expires_at': Cast.dateTime,
          'submitted_at': Cast.dateTime,
          'created_at': Cast.dateTime,
          'updated_at': Cast.dateTime,
        },
      );

  @override
  ModelDefinition<ExamSession> get modelDefinition => ExamSession.definition;

  static ModelQuery<ExamSession> query() => definition.query();
  static Future<ExamSession?> find(Object id) => query().find(id);
  static Future<ExamSession> findOrFail(Object id) => query().findOrFail(id);
  static Future<ExamSession> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<ExamSession>> all() => query().get();
  static ModelQuery<ExamSession> where(
    Object column, [
    Object? operatorOrValue = QueryBuilder.absent,
    Object? value = QueryBuilder.absent,
  ]) => query().where(column, operatorOrValue, value);

  String get id => getAttr('id') as String;
  set id(String value) => setAttr('id', value);

  int get candidateId => getAttr('candidate_id') as int;
  set candidateId(int value) => setAttr('candidate_id', value);

  String get deviceId => getAttr('device_id') as String;
  set deviceId(String value) => setAttr('device_id', value);

  String get token => getAttr('token') as String;
  set token(String value) => setAttr('token', value);

  DateTime get startedAt => getAttr('started_at') as DateTime;
  set startedAt(DateTime value) => setAttr('started_at', value);

  int get durationMinutes => (getAttr('duration_minutes') as int?) ?? 30;
  set durationMinutes(int value) => setAttr('duration_minutes', value);

  DateTime get expiresAt => getAttr('expires_at') as DateTime;
  set expiresAt(DateTime value) => setAttr('expires_at', value);

  DateTime? get submittedAt => getAttr('submitted_at') as DateTime?;
  set submittedAt(DateTime? value) => setAttr('submitted_at', value);

  String get status => (getAttr('status') as String?) ?? 'active';
  set status(String value) => setAttr('status', value);

  int? get scoreTwk => getAttr('score_twk') as int?;
  set scoreTwk(int? value) => setAttr('score_twk', value);

  int? get scoreTiu => getAttr('score_tiu') as int?;
  set scoreTiu(int? value) => setAttr('score_tiu', value);

  int? get scoreTkp => getAttr('score_tkp') as int?;
  set scoreTkp(int? value) => setAttr('score_tkp', value);

  int? get totalScore => getAttr('total_score') as int?;
  set totalScore(int? value) => setAttr('total_score', value);

  bool? get passingGradeMet => getAttr('passing_grade_met') as bool?;
  set passingGradeMet(bool? value) => setAttr('passing_grade_met', value);

  int? get ranking => getAttr('ranking') as int?;
  set ranking(int? value) => setAttr('ranking', value);

  int get seed => (getAttr('seed') as int?) ?? 42;
  set seed(int value) => setAttr('seed', value);

  DateTime? get createdAt => getAttr('created_at') as DateTime?;
  DateTime? get updatedAt => getAttr('updated_at') as DateTime?;
}
