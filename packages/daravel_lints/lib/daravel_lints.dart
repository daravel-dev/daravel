/// Daravel lint rules and architecture checks (BLUEPRINT_V2 §11).
///
/// Rules run on the AST from `package:analyzer` and are executed by
/// `dartisan lint`, by `daravel_test`'s architecture helpers and in CI.
/// (IDE squiggles need the analyzer plugin API of Dart 3.10+; until then the
/// rules run as a command.)
///
/// Silence a finding with `// daravel-lint-ignore: <rule>` on the same line
/// or the line above.
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

/// One finding.
final class LintIssue {
  const LintIssue({
    required this.rule,
    required this.message,
    required this.path,
    required this.line,
    required this.column,
  });

  final String rule;
  final String message;

  /// Path relative to the linted root (`/` separators).
  final String path;
  final int line;
  final int column;

  @override
  String toString() => '$path:$line:$column  $rule  $message';
}

/// A rule run against one parsed file.
abstract base class LintRule {
  const LintRule();

  String get name;

  String get description;

  /// Whether the rule applies to [relativePath] (`lib/app/x.dart`).
  bool appliesTo(String relativePath) => true;

  /// Reports findings through [report].
  void check(
    CompilationUnit unit,
    void Function(AstNode node, String message) report,
  );
}

/// `import 'dart:mirrors'` breaks AOT compilation (ADR: zero reflection).
final class NoDartMirrors extends LintRule {
  const NoDartMirrors();

  @override
  String get name => 'no_dart_mirrors';

  @override
  String get description => 'dart:mirrors is unavailable in AOT binaries.';

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    for (final directive in unit.directives) {
      if (directive is NamespaceDirective &&
          directive.uri.stringValue == 'dart:mirrors') {
        report(
          directive,
          'dart:mirrors is not supported in AOT builds; use explicit registries.',
        );
      }
    }
  }
}

/// `print()` in application code bypasses logging (redaction, context).
final class NoPrintInApp extends LintRule {
  const NoPrintInApp();

  @override
  String get name => 'no_print_in_app';

  @override
  String get description => 'Use Log instead of print in lib/.';

  @override
  bool appliesTo(String relativePath) => relativePath.startsWith('lib/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    unit.accept(
      _Visitor(
        onMethod: (node) {
          if (node.target == null && node.methodName.name == 'print') {
            report(
              node,
              'Use Log.info/debug instead of print (redaction and request context).',
            );
          }
        },
      ),
    );
  }
}

/// Mutable statics leak state between requests in long-running workers
/// (Octane-style pitfall).
final class NoMutableStaticInApp extends LintRule {
  const NoMutableStaticInApp();

  @override
  String get name => 'no_mutable_static_in_app';

  @override
  String get description => 'Static fields in lib/app must be final or const.';

  @override
  bool appliesTo(String relativePath) => relativePath.startsWith('lib/app/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    unit.accept(
      _Visitor(
        onField: (node) {
          if (node.isStatic && !node.fields.isFinal && !node.fields.isConst) {
            for (final variable in node.fields.variables) {
              report(
                variable,
                'Static field `${variable.name.lexeme}` is mutable and shared by every '
                'request in the isolate; make it final/const or use the container.',
              );
            }
          }
        },
        onTopLevel: (node) {
          if (!node.variables.isFinal && !node.variables.isConst) {
            for (final variable in node.variables.variables) {
              report(
                variable,
                'Top-level variable `${variable.name.lexeme}` is mutable global state; '
                'make it final/const or use the container.',
              );
            }
          }
        },
      ),
    );
  }
}

/// String interpolation into raw SQL is an injection risk; pass bindings.
final class NoSqlStringInterpolation extends LintRule {
  const NoSqlStringInterpolation();

  static const Set<String> sqlMethods = <String>{
    'select',
    'statement',
    'insertGetId',
    'raw',
    'selectRaw',
    'whereRaw',
    'orWhereRaw',
    'havingRaw',
    'orderByRaw',
    'groupByRaw',
    'fromRaw',
    // Unresolved ASTs parse `RawExpression(...)` as an invocation.
    'RawExpression',
  };

  @override
  String get name => 'no_sql_string_interpolation';

  @override
  String get description => 'Raw SQL must use bindings, not interpolation.';

  /// Application code only: framework internals (`lib/src/`) build SQL from
  /// grammar-quoted identifiers with bound values.
  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    void inspect(AstNode node, String callee, NodeList<Argument> arguments) {
      if (arguments.isEmpty) {
        return;
      }
      final sql = arguments.first.argumentExpression;
      if (_interpolates(sql)) {
        report(
          sql,
          'SQL passed to $callee is built with interpolation/concatenation; '
          'use placeholders (? or :name) and bindings.',
        );
      }
    }

    unit.accept(
      _Visitor(
        onMethod: (node) {
          if (sqlMethods.contains(node.methodName.name)) {
            inspect(node, node.methodName.name, node.argumentList.arguments);
          }
        },
        onCreation: (node) {
          if (node.constructorName.type.name.lexeme == 'RawExpression') {
            inspect(node, 'RawExpression', node.argumentList.arguments);
          }
        },
      ),
    );
  }

  static bool _interpolates(Expression expression) => switch (expression) {
    StringInterpolation() => true,
    AdjacentStrings(:final strings) => strings.any(_interpolates),
    BinaryExpression(
      :final operator,
      :final leftOperand,
      :final rightOperand,
    ) =>
      operator.type == TokenType.PLUS &&
          (leftOperand is StringLiteral ||
              rightOperand is StringLiteral ||
              _interpolates(leftOperand) ||
              _interpolates(rightOperand)),
    ParenthesizedExpression(:final expression) => _interpolates(expression),
    _ => false,
  };
}

/// Validation rule strings (`'required|emial|max:255'`) are parsed when
/// the route or request is defined; this reports unknown names and missing
/// or malformed arguments before that, in `.rules({...})`,
/// `.validate({...})`, `Validator(data, {...})` and `FormRequest.rules()`.
final class InvalidValidationRule extends LintRule {
  const InvalidValidationRule();

  /// Every name `RuleParser.parseOne` accepts (kept equal by
  /// `packages/daravel/test/validation/rule_names_lint_test.dart`).
  static const Set<String> knownRules = <String>{
    'required',
    'nullable',
    'sometimes',
    'bail',
    'present',
    'filled',
    'prohibited',
    'required_if',
    'required_unless',
    'required_with',
    'required_without',
    'string',
    'integer',
    'int',
    'numeric',
    'boolean',
    'bool',
    'array',
    'list',
    'map',
    'object',
    'email',
    'url',
    'file',
    'image',
    'mimes',
    'mimetypes',
    'extensions',
    'uuid',
    'ulid',
    'ip',
    'ipv4',
    'ipv6',
    'json',
    'alpha',
    'alpha_num',
    'alpha_dash',
    'ascii',
    'lowercase',
    'uppercase',
    'regex',
    'not_regex',
    'min',
    'max',
    'between',
    'size',
    'digits',
    'digits_between',
    'in',
    'not_in',
    'distinct',
    'confirmed',
    'same',
    'different',
    'starts_with',
    'ends_with',
    'date',
    'after',
    'after_or_equal',
    'before',
    'before_or_equal',
    'unique',
    'exists',
    'password',
  };

  /// Rules that need at least this many arguments.
  static const Map<String, int> requiredArguments = <String, int>{
    'required_if': 2,
    'required_unless': 2,
    'required_with': 1,
    'required_without': 1,
    'mimes': 1,
    'mimetypes': 1,
    'extensions': 1,
    'regex': 1,
    'not_regex': 1,
    'min': 1,
    'max': 1,
    'between': 2,
    'size': 1,
    'digits': 1,
    'digits_between': 2,
    'in': 1,
    'not_in': 1,
    'same': 1,
    'different': 1,
    'starts_with': 1,
    'ends_with': 1,
    'after': 1,
    'after_or_equal': 1,
    'before': 1,
    'before_or_equal': 1,
    'unique': 1,
    'exists': 1,
  };

  /// Rules whose arguments must be numbers (`int` for the digits rules).
  static const Set<String> numericArguments = <String>{
    'min',
    'max',
    'between',
    'size',
  };
  static const Set<String> integerArguments = <String>{
    'digits',
    'digits_between',
    'password',
  };

  @override
  String get name => 'invalid_validation_rule';

  @override
  String get description => 'Validation rule strings must parse.';

  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    void checkMap(Expression? expression) {
      if (expression is! SetOrMapLiteral) {
        return;
      }
      for (final element in expression.elements) {
        if (element is! MapLiteralEntry) {
          continue;
        }
        final value = element.value;
        final strings = value is ListLiteral
            ? value.elements.whereType<Expression>()
            : [value];
        for (final literal in strings) {
          final dsl = _literalText(literal);
          if (dsl == null) {
            continue;
          }
          final problem = problemIn(dsl);
          if (problem != null) {
            report(literal, problem);
          }
        }
      }
    }

    unit.accept(
      _Visitor(
        onMethod: (node) {
          final arguments = node.argumentList.arguments;
          switch (node.methodName.name) {
            case 'rules' || 'validate' when arguments.isNotEmpty:
              checkMap(arguments.first.argumentExpression);
            // Unresolved ASTs parse `Validator(data, {...})` as a call.
            case 'Validator' when arguments.length > 1:
              checkMap(arguments[1].argumentExpression);
          }
        },
        onCreation: (node) {
          final arguments = node.argumentList.arguments;
          if (node.constructorName.type.name.lexeme == 'Validator' &&
              arguments.length > 1) {
            checkMap(arguments[1].argumentExpression);
          }
        },
        onMethodDeclaration: (node) {
          if (node.name.lexeme != 'rules') {
            return;
          }
          switch (node.body) {
            case ExpressionFunctionBody(:final expression):
              checkMap(expression);
            case BlockFunctionBody(:final block):
              for (final statement in block.statements) {
                if (statement is ReturnStatement) {
                  checkMap(statement.expression);
                }
              }
            case EmptyFunctionBody() || NativeFunctionBody():
              break;
          }
        },
      ),
    );
  }

  /// The first problem in [dsl], or null when every segment parses.
  static String? problemIn(String dsl) {
    for (final raw in dsl.split('|')) {
      final segment = raw.trim();
      if (segment.isEmpty) {
        continue;
      }
      final colon = segment.indexOf(':');
      final rule = colon == -1 ? segment : segment.substring(0, colon);
      final arguments = colon == -1
          ? const <String>[]
          : [
              for (final a in segment.substring(colon + 1).split(','))
                if (a.trim().isNotEmpty) a.trim(),
            ];
      if (!knownRules.contains(rule)) {
        return 'Unknown validation rule "$rule" in "$dsl".';
      }
      final needed = requiredArguments[rule] ?? 0;
      if (arguments.length < needed) {
        return 'Validation rule "$rule" needs $needed argument'
            '${needed == 1 ? '' : 's'} ("$rule:${List.filled(needed, '...').join(',')}") '
            'in "$dsl".';
      }
      final badNumber = numericArguments.contains(rule)
          ? arguments.where((a) => num.tryParse(a) == null)
          : integerArguments.contains(rule)
          ? arguments.where((a) => int.tryParse(a) == null)
          : const <String>[];
      if (badNumber.isNotEmpty) {
        return 'Validation rule "$rule" expects a number, got '
            '"${badNumber.first}" in "$dsl".';
      }
    }
    return null;
  }

  static String? _literalText(Expression expression) => switch (expression) {
    SimpleStringLiteral(:final value) => value,
    AdjacentStrings(:final strings) =>
      strings.every((s) => s is SimpleStringLiteral)
          ? strings.map((s) => (s as SimpleStringLiteral).value).join()
          : null,
    _ => null,
  };
}

/// A query started inside `DB.transaction(() async { ... })` without
/// `await` runs after the transaction has finished, outside it (Daravel then
/// throws a StateError). `unawaited_futures` misses explicit `unawaited()`
/// and `.ignore()`, and projects may not enable it.
final class UnawaitedInDbTransaction extends LintRule {
  const UnawaitedInDbTransaction();

  /// Methods that only exist on the query builder, the ORM or a model.
  static const Set<String> queryMethods = <String>{
    'save',
    'insert',
    'insertGetId',
    'insertOrIgnore',
    'upsert',
    'statement',
    'forceDelete',
    'restore',
    'touch',
    'attach',
    'detach',
    'sync',
    'increment',
    'decrement',
    'create',
    'createMany',
    'firstOrCreate',
    'updateOrCreate',
    'transaction',
  };

  /// Common names that count only on a chain that starts like a query.
  static const Set<String> chainMethods = <String>{
    'get',
    'first',
    'firstOrFail',
    'find',
    'findOrFail',
    'pluck',
    'count',
    'exists',
    'delete',
    'update',
    'paginate',
    'sum',
    'avg',
    'min',
    'max',
  };

  @override
  String get name => 'unawaited_in_db_transaction';

  @override
  String get description =>
      'Queries inside DB.transaction must be awaited (or returned).';

  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    unit.accept(
      _Visitor(
        onMethod: (node) {
          if (node.methodName.name != 'transaction') {
            return;
          }
          for (final argument in node.argumentList.arguments) {
            final body = argument.argumentExpression;
            if (body is FunctionExpression) {
              body.body.accept(_TransactionBodyScanner(report));
            }
          }
        },
      ),
    );
  }

  /// Whether [expression] is a call chain that runs a query.
  static bool isQuery(Expression expression) {
    final names = <String>[];
    String? root;
    Expression? current = expression;
    while (current != null) {
      switch (current) {
        case MethodInvocation(:final methodName, :final target):
          names.add(methodName.name);
          current = target;
        case PropertyAccess(:final propertyName, :final target):
          names.add(propertyName.name);
          current = target;
        case PrefixedIdentifier(:final prefix, :final identifier):
          names.add(identifier.name);
          root = prefix.name;
          current = null;
        case SimpleIdentifier(:final name):
          root = name;
          current = null;
        case ParenthesizedExpression(:final expression):
          current = expression;
        default:
          current = null;
      }
    }
    if (names.any(queryMethods.contains)) {
      return true;
    }
    final startsLikeQuery =
        root == 'DB' ||
        names.any((n) => n == 'table' || n == 'query' || n.startsWith('where'));
    return startsLikeQuery && names.any(chainMethods.contains);
  }
}

/// Finds fire-and-forget queries in one transaction body. Nested closures
/// are skipped: callbacks such as `afterCommit(() => ...)` run later on
/// purpose, and nested transactions are checked on their own.
final class _TransactionBodyScanner extends RecursiveAstVisitor<void> {
  _TransactionBodyScanner(this.report);

  final void Function(AstNode node, String message) report;

  static const String _message =
      'Query is not awaited inside DB.transaction: it would run after the '
      'transaction finishes. Add `await` (or return it).';

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    final expression = node.expression;
    if (expression is! AwaitExpression &&
        UnawaitedInDbTransaction.isQuery(expression)) {
      report(expression, _message);
      return;
    }
    super.visitExpressionStatement(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final target = node.target;
    final arguments = node.argumentList.arguments;
    final ignored =
        (target == null &&
            node.methodName.name == 'unawaited' &&
            arguments.length == 1 &&
            UnawaitedInDbTransaction.isQuery(
              arguments.single.argumentExpression,
            )) ||
        (node.methodName.name == 'ignore' &&
            target != null &&
            UnawaitedInDbTransaction.isQuery(target));
    if (ignored) {
      report(node, _message);
      return;
    }
    super.visitMethodInvocation(node);
  }
}

final class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor({
    this.onMethod,
    this.onField,
    this.onTopLevel,
    this.onCreation,
    this.onMethodDeclaration,
  });

  final void Function(MethodInvocation node)? onMethod;
  final void Function(MethodDeclaration node)? onMethodDeclaration;
  final void Function(FieldDeclaration node)? onField;
  final void Function(TopLevelVariableDeclaration node)? onTopLevel;
  final void Function(InstanceCreationExpression node)? onCreation;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    onMethod?.call(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    onMethodDeclaration?.call(node);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    onField?.call(node);
    super.visitFieldDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    onTopLevel?.call(node);
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    onCreation?.call(node);
    super.visitInstanceCreationExpression(node);
  }
}

/// Every built-in rule.
const List<LintRule> defaultRules = <LintRule>[
  NoDartMirrors(),
  NoPrintInApp(),
  NoMutableStaticInApp(),
  NoSqlStringInterpolation(),
  UnawaitedInDbTransaction(),
  InvalidValidationRule(),
];

/// Lints Dart [source] whose project-relative path is [relativePath].
List<LintIssue> lintSource(
  String source,
  String relativePath, {
  List<LintRule> rules = defaultRules,
}) {
  final normalized = relativePath.replaceAll(r'\', '/');
  final parsed = parseString(
    content: source,
    path: normalized,
    throwIfDiagnostics: false,
  );
  final lines = source.split('\n');
  final issues = <LintIssue>[];
  for (final rule in rules) {
    if (!rule.appliesTo(normalized)) {
      continue;
    }
    rule.check(parsed.unit, (node, message) {
      final location = parsed.lineInfo.getLocation(node.offset);
      if (_suppressed(lines, location, rule.name)) {
        return;
      }
      issues.add(
        LintIssue(
          rule: rule.name,
          message: message,
          path: normalized,
          line: location.lineNumber,
          column: location.columnNumber,
        ),
      );
    });
  }
  return issues;
}

bool _suppressed(List<String> lines, CharacterLocation location, String rule) {
  bool mentions(int index) =>
      index >= 0 &&
      index < lines.length &&
      RegExp('daravel-lint-ignore:[^\\n]*\\b${RegExp.escape(rule)}\\b')
          .hasMatch(lines[index]);
  return mentions(location.lineNumber - 1) || mentions(location.lineNumber - 2);
}

/// Lints every Dart file under [directories] of the project at [root].
List<LintIssue> lintProject(
  String root, {
  List<String> directories = const <String>[
    'lib',
    'bin',
    'bootstrap',
    'routes',
    'database',
  ],
  List<LintRule> rules = defaultRules,
}) {
  final issues = <LintIssue>[];
  for (final directory in directories) {
    final dir = Directory(p.join(root, directory));
    if (!dir.existsSync()) {
      continue;
    }
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      issues.addAll(
        lintSource(
          file.readAsStringSync(),
          p.relative(file.path, from: root),
          rules: rules,
        ),
      );
    }
  }
  return issues..addAll(checkRegistries(root));
}

/// Convention folder → registry file that must import every file in it.
const Map<String, String> registryConventions = <String, String>{
  'database/migrations': 'bootstrap/migrations.dart',
  'database/seeders': 'bootstrap/seeders.dart',
  'lib/app/jobs': 'bootstrap/jobs.dart',
  'lib/app/console/commands': 'bootstrap/commands.dart',
};

/// `registry_entry_missing`: classes in convention folders that no registry
/// imports (they would silently never run — ADR-002).
List<LintIssue> checkRegistries(
  String root, {
  Map<String, String> conventions = registryConventions,
}) {
  final issues = <LintIssue>[];
  for (final entry in conventions.entries) {
    final dir = Directory(p.join(root, entry.key));
    final registry = File(p.join(root, entry.value));
    if (!dir.existsSync()) {
      continue;
    }
    final registered = registry.existsSync() ? registry.readAsStringSync() : '';
    for (final file in dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.dart'),
    )) {
      final name = p.basename(file.path);
      if (!registered.contains('/$name\'')) {
        issues.add(
          LintIssue(
            rule: 'registry_entry_missing',
            message:
                '${entry.key}/$name is not imported by ${entry.value}; '
                'it will never run. Add it to the registry (dartisan make:* does this).',
            path: p.relative(file.path, from: root).replaceAll(r'\', '/'),
            line: 1,
            column: 1,
          ),
        );
      }
    }
  }
  return issues;
}
