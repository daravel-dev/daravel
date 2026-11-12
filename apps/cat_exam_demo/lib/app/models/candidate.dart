import 'package:daravel/daravel.dart';

/// Candidate model for CAT / TKA examinations.
final class Candidate extends Model {
  static final ModelDefinition<Candidate> definition =
      ModelDefinition<Candidate>(
        table: 'candidates',
        factory: Candidate.new,
        fillable: [
          'nik',
          'exam_number',
          'name',
          'device_id',
          'active_session_id',
          'status',
        ],
        casts: {
          'id': Cast.integer,
          'created_at': Cast.dateTime,
          'updated_at': Cast.dateTime,
        },
      );

  @override
  ModelDefinition<Candidate> get modelDefinition => Candidate.definition;

  static ModelQuery<Candidate> query() => definition.query();
  static Future<Candidate?> find(Object id) => query().find(id);
  static Future<Candidate> findOrFail(Object id) => query().findOrFail(id);
  static Future<Candidate> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<Candidate>> all() => query().get();
  static ModelQuery<Candidate> where(
    Object column, [
    Object? operatorOrValue = QueryBuilder.absent,
    Object? value = QueryBuilder.absent,
  ]) => query().where(column, operatorOrValue, value);
  static ModelQuery<Candidate> whereIn(String column, Object values) =>
      query().whereIn(column, values);

  int get id => getAttr('id') as int;
  String get nik => getAttr('nik') as String;
  set nik(String value) => setAttr('nik', value);

  String get examNumber => getAttr('exam_number') as String;
  set examNumber(String value) => setAttr('exam_number', value);

  String get name => getAttr('name') as String;
  set name(String value) => setAttr('name', value);

  String? get deviceId => getAttr('device_id') as String?;
  set deviceId(String? value) => setAttr('device_id', value);

  String? get activeSessionId => getAttr('active_session_id') as String?;
  set activeSessionId(String? value) => setAttr('active_session_id', value);

  String get status => (getAttr('status') as String?) ?? 'registered';
  set status(String value) => setAttr('status', value);

  DateTime? get createdAt => getAttr('created_at') as DateTime?;
  DateTime? get updatedAt => getAttr('updated_at') as DateTime?;
}
