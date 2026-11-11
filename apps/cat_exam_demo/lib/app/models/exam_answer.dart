import 'package:daravel/daravel.dart';

/// Real-time answer saved by a candidate during an exam.
final class ExamAnswer extends Model {
  static final ModelDefinition<ExamAnswer> definition =
      ModelDefinition<ExamAnswer>(
        table: 'exam_answers',
        factory: ExamAnswer.new,
        fillable: [
          'session_id',
          'candidate_id',
          'question_id',
          'selected_option',
          'is_doubtful',
          'idempotency_key',
          'answered_at',
        ],
        casts: {
          'id': Cast.integer,
          'candidate_id': Cast.integer,
          'question_id': Cast.integer,
          'is_doubtful': Cast.boolean,
          'answered_at': Cast.dateTime,
          'created_at': Cast.dateTime,
          'updated_at': Cast.dateTime,
        },
      );

  @override
  ModelDefinition<ExamAnswer> get modelDefinition => ExamAnswer.definition;

  static ModelQuery<ExamAnswer> query() => definition.query();
  static Future<ExamAnswer?> find(Object id) => query().find(id);
  static Future<ExamAnswer> findOrFail(Object id) => query().findOrFail(id);
  static Future<ExamAnswer> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<ExamAnswer>> all() => query().get();
  static ModelQuery<ExamAnswer> where(
    Object column, [
    Object? operatorOrValue = QueryBuilder.absent,
    Object? value = QueryBuilder.absent,
  ]) => query().where(column, operatorOrValue, value);

  int get id => getAttr('id') as int;

  String get sessionId => getAttr('session_id') as String;
  set sessionId(String value) => setAttr('session_id', value);

  int get candidateId => getAttr('candidate_id') as int;
  set candidateId(int value) => setAttr('candidate_id', value);

  int get questionId => getAttr('question_id') as int;
  set questionId(int value) => setAttr('question_id', value);

  String get selectedOption => getAttr('selected_option') as String;
  set selectedOption(String value) => setAttr('selected_option', value);

  bool get isDoubtful => (getAttr('is_doubtful') as bool?) ?? false;
  set isDoubtful(bool value) => setAttr('is_doubtful', value);

  String get idempotencyKey => (getAttr('idempotency_key') as String?) ?? '';
  set idempotencyKey(String value) => setAttr('idempotency_key', value);

  DateTime? get answeredAt => getAttr('answered_at') as DateTime?;
  set answeredAt(DateTime? value) => setAttr('answered_at', value);

  DateTime? get createdAt => getAttr('created_at') as DateTime?;
  DateTime? get updatedAt => getAttr('updated_at') as DateTime?;
}
