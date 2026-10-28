import 'package:daravel/daravel.dart';
import 'package:daravel_activitylog/daravel_activitylog.dart';
import 'package:daravel_permission/daravel_permission.dart';

/// A teacher or a student: the `teacher` and `student` roles
/// (`daravel_permission`) say which.
final class User extends Model
    with AuthenticatableModel, HasRoles, CausesActivity {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  static ModelQuery<User> query() => definition.query();

  int get id => getAttr<num>('id').toInt();
  String get name => getAttr('name');
  String get email => getAttr('email');

  Future<bool> get isTeacher => hasRole('teacher');
}
