import 'package:daravel/daravel.dart';

/// Question in the CAT question bank (TWK, TIU, TKP).
final class ExamQuestion extends Model {
  static final ModelDefinition<ExamQuestion> definition =
      ModelDefinition<ExamQuestion>(
        table: 'questions',
        factory: ExamQuestion.new,
        fillable: [
          'category',
          'question_text',
          'options',
          'correct_option',
          'weight',
        ],
        casts: {
          'id': Cast.integer,
          'options': Cast.json,
          'weight': Cast.integer,
          'created_at': Cast.dateTime,
          'updated_at': Cast.dateTime,
        },
      );

  @override
  ModelDefinition<ExamQuestion> get modelDefinition => ExamQuestion.definition;

  static ModelQuery<ExamQuestion> query() => definition.query();
  static Future<ExamQuestion?> find(Object id) => query().find(id);
  static Future<ExamQuestion> findOrFail(Object id) => query().findOrFail(id);
  static Future<ExamQuestion> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<ExamQuestion>> all() => query().get();
  static ModelQuery<ExamQuestion> where(
    Object column, [
    Object? op,
    Object? value,
  ]) => query().where(column, op, value);

  int get id => getAttr<int>('id');

  String get category => getAttr<String>('category');
  set category(String value) => setAttr('category', value);

  String get questionText => getAttr<String>('question_text');
  set questionText(String value) => setAttr('question_text', value);

  List<Map<String, Object?>> get options {
    final raw = getAttr<Object?>('options');
    if (raw is List) {
      return raw.map((item) => (item as Map).cast<String, Object?>()).toList();
    }
    return const [];
  }

  set options(List<Map<String, Object?>> value) => setAttr('options', value);

  String? get correctOption => getAttr<String?>('correct_option');
  set correctOption(String? value) => setAttr('correct_option', value);

  int get weight => getAttr<int?>('weight') ?? 5;
  set weight(int value) => setAttr('weight', value);

  DateTime? get createdAt => getAttr<DateTime?>('created_at');
  DateTime? get updatedAt => getAttr<DateTime?>('updated_at');
}
