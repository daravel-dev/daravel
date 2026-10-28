import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Public declarations of a set of libraries: types with their members and
/// supertypes, plus top-level functions and variables.
final class _Declarations {
  final Map<String, Set<String>> members = {};
  final Map<String, Set<String>> supertypes = {};
  final Set<String> topLevel = {};

  void addType(
    String name,
    Iterable<String> memberNames,
    Iterable<String> supers,
  ) {
    members.putIfAbsent(name, () => {}).addAll(memberNames);
    supertypes.putIfAbsent(name, () => {}).addAll(supers);
  }

  /// Whether [type] declares or inherits [member].
  bool hasMember(String type, String member, [Set<String>? seen]) {
    final visited = seen ?? <String>{};
    if (!visited.add(type)) {
      return false;
    }
    if (members[type]?.contains(member) ?? false) {
      return true;
    }
    return (supertypes[type] ?? const <String>{}).any(
      (parent) => hasMember(parent, member, visited),
    );
  }

  void scan(String directory) {
    for (final file in Directory(directory).listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) {
        continue;
      }
      final unit = parseFile(
        path: p.normalize(file.absolute.path),
        featureSet: FeatureSet.latestLanguageVersion(),
      ).unit;
      for (final declaration in unit.declarations) {
        _declaration(declaration);
      }
    }
  }

  void _declaration(CompilationUnitMember node) {
    switch (node) {
      case ClassDeclaration():
        addType(node.namePart.typeName.lexeme, _members(node.body.members), [
          ?node.extendsClause?.superclass.name.lexeme,
          ...?node.withClause?.mixinTypes.map((t) => t.name.lexeme),
          ...?node.implementsClause?.interfaces.map((t) => t.name.lexeme),
        ]);
      case MixinDeclaration():
        addType(node.name.lexeme, _members(node.body.members), [
          ...?node.implementsClause?.interfaces.map((t) => t.name.lexeme),
        ]);
      case EnumDeclaration():
        addType(node.namePart.typeName.lexeme, [
          ...node.body.constants.map((c) => c.name.lexeme),
          ..._members(node.body.members),
        ], const []);
      case ExtensionTypeDeclaration():
        addType(
          node.namePart.typeName.lexeme,
          _members(node.body.members),
          const [],
        );
      case ExtensionDeclaration():
        // Members count for the extension's own name and the extended type.
        final members = _members(node.body.members).toList();
        final name = node.name?.lexeme;
        if (name != null) {
          addType(name, members, const []);
        }
        final on = node.onClause?.extendedType;
        if (on is NamedType) {
          addType(on.name.lexeme, members, const []);
        }
      case FunctionDeclaration():
        topLevel.add(node.name.lexeme);
      case TopLevelVariableDeclaration():
        topLevel.addAll(node.variables.variables.map((v) => v.name.lexeme));
      case GenericTypeAlias():
        topLevel.add(node.name.lexeme);
      default:
        break;
    }
  }

  static Iterable<String> _members(Iterable<ClassMember> members) sync* {
    for (final member in members) {
      switch (member) {
        case MethodDeclaration():
          yield member.name.lexeme;
        case FieldDeclaration():
          yield* member.fields.variables.map((v) => v.name.lexeme);
        case ConstructorDeclaration():
          final name = member.name?.lexeme;
          if (name != null) {
            yield name;
          }
        default:
          break;
      }
    }
  }
}

/// ADR-016: every `symbol` in `parity.yaml` must exist in Daravel, so the
/// parity table (and the docs generated from it) cannot drift from the code.
void main() {
  final root = p.normalize(p.join(Directory.current.path, '..', '..'));
  final declarations = _Declarations()
    ..scan(p.join(root, 'packages', 'daravel', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_test', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_redis', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_s3', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_permission', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_activitylog', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_excel', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_log_viewer', 'lib'))
    ..scan(p.join(root, 'packages', 'daravel_teorion', 'lib'));
  final parity =
      loadYaml(File(p.join(root, 'parity.yaml')).readAsStringSync()) as YamlMap;

  test('parity.yaml header', () {
    expect(parity['parityVersion'], 1);
    expect(parity['laravel'], '12.x');
  });

  final sections = parity['sections'] as YamlList;
  for (final section in sections.cast<YamlMap>()) {
    test('symbols of ${section['name']} exist in Daravel', () {
      final missing = <String>[];
      for (final entry in (section['symbols'] as YamlList).cast<YamlMap>()) {
        expect(entry['php'], isA<String>());
        expect(entry['dart'], isA<String>());
        final symbol = entry['symbol'] as String;
        final dot = symbol.indexOf('.');
        final found = dot == -1
            ? declarations.members.containsKey(symbol) ||
                  declarations.topLevel.contains(symbol)
            : declarations.hasMember(
                symbol.substring(0, dot),
                symbol.substring(dot + 1),
              );
        if (!found) {
          missing.add('$symbol (${entry['php']})');
        }
      }
      expect(missing, isEmpty, reason: 'parity.yaml symbols not found');
    });
  }

  test('exceptions map to Daravel types', () {
    final exceptions = parity['exceptions'] as YamlMap;
    for (final name in exceptions.values.cast<String>()) {
      expect(declarations.members.containsKey(name), isTrue, reason: name);
    }
  });
}
