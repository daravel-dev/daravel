import 'package:daravel/daravel.dart';

/// Application user (Laravel's default `User` model).
///
/// The `definition`, statics and accessors follow the layout that
/// `dartisan make:model` generates; edit freely outside the marked regions.
final class User extends Model {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password', 'remember_token'],
    casts: {
      'email_verified_at': Cast.dateTime,
      'created_at': Cast.dateTime,
      'updated_at': Cast.dateTime,
    },
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  // <dartisan:statics>
  static ModelQuery<User> query() => definition.query();
  static Future<User?> find(Object id) => query().find(id);
  static Future<User> findOrFail(Object id) => query().findOrFail(id);
  static Future<User> create(Map<String, Object?> attributes) =>
      query().create(attributes);
  static Future<ModelCollection<User>> all() => query().get();
  static ModelQuery<User> where(Object column, [Object? op, Object? value]) =>
      query().where(column, op, value);
  // </dartisan:statics>

  // <dartisan:accessors>
  int get id => getAttr('id');
  String get name => getAttr('name');
  set name(String value) => setAttr('name', value);
  String get email => getAttr('email');
  set email(String value) => setAttr('email', value);
  String get password => getAttr('password');
  set password(String value) => setAttr('password', value);
  DateTime? get emailVerifiedAt => getAttr('email_verified_at');
  DateTime? get createdAt => getAttr('created_at');
  DateTime? get updatedAt => getAttr('updated_at');
  // </dartisan:accessors>
}
