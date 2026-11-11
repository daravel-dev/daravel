import 'package:daravel/daravel.dart';

/// Application user (Laravel's default `User` model).
///
/// [AuthenticatableModel] makes it usable by the auth guards; the
/// `definition`, statics and accessors follow the layout that
/// `dartisan make:model` generates; edit freely outside the marked regions.
final class User extends Model with AuthenticatableModel {
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
  /// The columns of `users`, for typed queries: `User.cols.id`.
  static const cols = (
    id: ModelColumn<User, int>('id'),
    name: ModelColumn<User, String>('name'),
    email: ModelColumn<User, String>('email'),
    emailVerifiedAt: ModelColumn<User, DateTime?>('email_verified_at'),
    password: ModelColumn<User, String>('password'),
    rememberToken: ModelColumn<User, String?>('remember_token'),
    createdAt: ModelColumn<User, DateTime?>('created_at'),
    updatedAt: ModelColumn<User, DateTime?>('updated_at'),
  );
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

  /// Creates and saves a `User` (`create` with a map, checked by
  /// the compiler): a `required` column has no default.
  static Future<User> createWith({
    required String name,
    required String email,
    required String password,
  }) => definition.query().create(<String, Object?>{
    'name': name,
    'email': email,
    'password': password,
  });

  /// [createWith] without saving (`make`).
  static User makeWith({
    required String name,
    required String email,
    required String password,
  }) => definition.query().make(<String, Object?>{
    'name': name,
    'email': email,
    'password': password,
  });

  /// Fills the given columns (`fill`); `Patch(null)` sets a nullable
  /// one to null.
  User fillWith({String? name, String? email, String? password}) {
    fill(<String, Object?>{
      'name': ?name,
      'email': ?email,
      'password': ?password,
    });
    return this;
  }

  /// Updates the given columns and saves (`update`); `Patch(null)` sets a
  /// nullable one to null.
  Future<bool> updateWith({String? name, String? email, String? password}) =>
      update(<String, Object?>{
        'name': ?name,
        'email': ?email,
        'password': ?password,
      });
  // </dartisan:accessors>
}
