import 'package:daravel/daravel.dart';

import 'user.dart';

/// A class taught by one teacher to its students (`classroom_student`).
final class Classroom extends Model {
  static final ModelDefinition<Classroom> definition =
      ModelDefinition<Classroom>(
        table: 'classrooms',
        factory: Classroom.new,
        fillable: ['name', 'teacher_id'],
        relations: {
          'teacher': () =>
              BelongsTo<User>(() => User.definition, foreignKey: 'teacher_id'),
          'students': () => BelongsToMany<User>(
            () => User.definition,
            pivotTable: 'classroom_student',
            foreignPivotKey: 'classroom_id',
            relatedPivotKey: 'user_id',
          ),
        },
      );

  @override
  ModelDefinition<Classroom> get modelDefinition => Classroom.definition;

  static ModelQuery<Classroom> query() => definition.query();

  int get id => getAttr<num>('id').toInt();
  String get name => getAttr('name');
  int get teacherId => getAttr<num>('teacher_id').toInt();

  /// The ids of the classrooms [user] teaches or attends.
  static Future<List<int>> idsOf(User user) async {
    final taught = await DB
        .table('classrooms')
        .where('teacher_id', user.id)
        .pluck('id');
    final attended = await DB
        .table('classroom_student')
        .where('user_id', user.id)
        .pluck('classroom_id');
    return [
      for (final id in [
        ...taught as List<Object?>,
        ...attended as List<Object?>,
      ])
        (id! as num).toInt(),
    ];
  }

  /// Whether [user] teaches this classroom.
  bool taughtBy(User user) => teacherId == user.id;

  /// Whether [user] is one of its students.
  Future<bool> attendedBy(User user) => DB
      .table('classroom_student')
      .where('classroom_id', id)
      .where('user_id', user.id)
      .exists();

  /// The students' e-mail addresses, for calendar invitations.
  Future<List<String>> studentEmails() async {
    final emails = await DB
        .table('users')
        .join('classroom_student', 'users.id', '=', 'classroom_student.user_id')
        .where('classroom_student.classroom_id', id)
        .orderBy('users.id')
        .pluck('users.email');
    return [for (final email in emails as List<Object?>) email! as String];
  }
}
