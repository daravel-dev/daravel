import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// The typed columns of a project's models, as `dartisan model:sync` wrote
/// them into each model's `cols` record:
///
/// ```dart
/// static const cols = (
///   email: ModelColumn<User, String>('email'),
///   emailVerifiedAt: ModelColumn<User, DateTime?>('email_verified_at'),
/// );
/// ```
///
/// gives `User` → {`email` → `email`, `email_verified_at` →
/// `emailVerifiedAt`}. The field of a column is read, never derived from
/// its name: `model:sync` renames a field that would clash.
final class ModelColumnIndex {
  /// An index of [fields]: model class → column → field of `cols`; and
  /// [superclasses], class → the class it extends, for [modelClasses].
  ModelColumnIndex(
    Map<String, Map<String, String>> fields, {
    Map<String, String> superclasses = const {},
  }) : _fields = {
         for (final MapEntry(:key, :value) in fields.entries)
           key: Map.unmodifiable(value),
       },
       _superclasses = Map.unmodifiable(superclasses);

  /// Reads every `*.dart` file under `[root]/lib/app/models`.
  factory ModelColumnIndex.scan(String root) {
    final directory = Directory(p.join(root, 'lib', 'app', 'models'));
    if (!directory.existsSync()) {
      return ModelColumnIndex(const {});
    }
    final files =
        directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return ModelColumnIndex.ofSources([
      for (final file in files) file.readAsStringSync(),
    ]);
  }

  /// The `cols` records of the classes in [sources], the model files in
  /// path order (a class declared twice: the later one wins, as in
  /// [ModelColumnIndex.scan]). The editor plugin reads the files through
  /// the analysis server, so unsaved changes count.
  factory ModelColumnIndex.ofSources(Iterable<String> sources) =>
      ModelColumnIndex.merge([
        for (final source in sources) ModelColumnIndex.ofSource(source),
      ]);

  /// One index of the models of [indexes] (a class in two: the later one
  /// wins).
  factory ModelColumnIndex.merge(Iterable<ModelColumnIndex> indexes) {
    final list = indexes.toList();
    return ModelColumnIndex(
      {for (final index in list) ...index._fields},
      superclasses: {for (final index in list) ...index._superclasses},
    );
  }

  /// The `cols` records of the classes in [source], and the class each
  /// class extends.
  factory ModelColumnIndex.ofSource(String source) {
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;
    final fields = <String, Map<String, String>>{};
    final superclasses = <String, String>{};
    for (final declaration in unit.declarations.whereType<ClassDeclaration>()) {
      final name = declaration.namePart.typeName.lexeme;
      final columns = _colsOf(declaration);
      if (columns != null) {
        fields[name] = columns;
      }
      final superclass = declaration.extendsClause?.superclass.name.lexeme;
      if (superclass != null) {
        superclasses[name] = superclass;
      }
    }
    return ModelColumnIndex(fields, superclasses: superclasses);
  }

  final Map<String, Map<String, String>> _fields;
  final Map<String, String> _superclasses;

  /// The model classes with a `cols` record.
  Iterable<String> get models => _fields.keys;

  /// The classes of the index that are models: they extend `Model`, or a
  /// class of the index that does (`Region extends BaseModel`,
  /// `BaseModel extends Model`). A chain that leaves the index is not
  /// followed: a class it does not know is not guessed to be a model.
  Set<String> get modelClasses => {
    for (final name in _superclasses.keys)
      if (_reachesModel(name)) name,
  };

  bool _reachesModel(String name) {
    final seen = <String>{};
    for (
      String? current = name;
      current != null;
      current = _superclasses[current]
    ) {
      if (current == 'Model') {
        return true;
      }
      if (!seen.add(current)) {
        return false;
      }
    }
    return false;
  }

  /// The field of `[model].cols` for [column], `null` when there is none.
  String? fieldOf(String model, String column) => _fields[model]?[column];

  static Map<String, String>? _colsOf(ClassDeclaration declaration) {
    for (final member in declaration.body.members) {
      if (member is! FieldDeclaration || !member.isStatic) {
        continue;
      }
      for (final variable in member.fields.variables) {
        final initializer = variable.initializer;
        if (variable.name.lexeme != 'cols' || initializer is! RecordLiteral) {
          continue;
        }
        final columns = <String, String>{};
        for (final field
            in initializer.fields.whereType<RecordLiteralNamedField>()) {
          final column = _columnName(field.fieldExpression);
          if (column != null) {
            columns[column] = field.name.lexeme;
          }
        }
        return columns;
      }
    }
    return null;
  }

  /// `'email'` of `ModelColumn<User, String>('email')`.
  static String? _columnName(Expression expression) {
    final ArgumentList arguments;
    switch (expression) {
      case InstanceCreationExpression(
            :final constructorName,
            :final argumentList,
          )
          when constructorName.type.name.lexeme == 'ModelColumn':
        arguments = argumentList;
      // Unresolved, `ModelColumn<User, String>('email')` is a call.
      case MethodInvocation(:final methodName, :final argumentList)
          when methodName.name == 'ModelColumn':
        arguments = argumentList;
      default:
        return null;
    }
    final first = arguments.arguments.firstOrNull;
    return first is SimpleStringLiteral ? first.value : null;
  }
}
