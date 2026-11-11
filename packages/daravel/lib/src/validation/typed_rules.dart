import '../database/orm/model.dart';
import '../database/orm/model_definition.dart';
import '../database/orm/typed_columns.dart';
import 'rule.dart';
import 'rules.dart';

/// An input field of a form request, named once and typed: its [name] is
/// the key of `rules()`, `messages()` and `attributes()`, and [T] is the
/// type a typed input reads it as.
///
/// ```dart
/// static const email = Field<String>('email');
///
/// Map<String, Object> rules(Request request) => {
///   email: [Rules.required(), Rules.email()],
/// };
/// Map<String, String> messages() => {email.on(Rules.required()): '...'};
/// ```
///
/// It is a `String`, so every API that takes a field name takes it
/// (`Rules.same(password)`, `Rules.requiredIf(role, 'admin')`), and a
/// misspelt field does not compile.
extension type const Field<T>(String name) implements String {
  /// The key of a custom message for [rule] on this field
  /// (`email.required`), from the rule's own name.
  String on(Rule rule) => '$name.${rule.name}';
}

/// The rules that read a model's table, typed by its columns: made by
/// [Rules.of].
///
/// ```dart
/// Rules.of(User.definition).unique(User.cols.email)
/// Rules.of(Post.definition).exists(Post.cols.id)
/// ```
///
/// The model is fixed by `Rules.of`, so a column of another model is a
/// compile error (a two-argument `uniqueIn(definition, column)` would let
/// Dart infer `Model` for both and accept it).
extension type const ModelRules<M extends Model>(ModelDefinition<M> definition)
    implements Object {
  /// `unique:table,column`: no row of the model's table holds the value in
  /// [column]; [ignore] skips the row whose [idColumn] (the primary key by
  /// default) is that value, for updates.
  UniqueRule unique(
    ModelColumn<M, Object?> column, {
    Object? ignore,
    ModelColumn<M, Object?>? idColumn,
  }) => UniqueRule(
    definition.table,
    column: column.name,
    ignore: ignore,
    idColumn: idColumn?.name ?? definition.primaryKey,
  );

  /// `exists:table,column`: a row of the model's table holds the value in
  /// [column].
  ExistsRule exists(ModelColumn<M, Object?> column) =>
      ExistsRule(definition.table, column: column.name);
}
