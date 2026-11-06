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
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// One finding.
final class LintIssue {
  /// A finding of [rule] at a line and column.
  const LintIssue({
    required this.rule,
    required this.message,
    required this.path,
    required this.line,
    required this.column,
  });

  /// The rule that found it.
  final String rule;

  /// What is wrong and how to fix it.
  final String message;

  /// Path relative to the linted root (`/` separators).
  final String path;

  /// The line, from 1.
  final int line;

  /// The column, from 1.
  final int column;

  @override
  String toString() => '$path:$line:$column  $rule  $message';
}

/// A rule run against one parsed file.
abstract base class LintRule {
  /// Rules are usually const.
  const LintRule();

  /// The rule's name, used by `// daravel-lint-ignore: <name>`.
  String get name;

  /// What the rule checks.
  String get description;

  /// Whether the rule applies to [relativePath] (`lib/app/x.dart`).
  bool appliesTo(String relativePath) => true;

  /// Reports findings through [report].
  void check(
    CompilationUnit unit,
    void Function(AstNode node, String message) report,
  );

  /// Reports findings at a source offset, for rules that point inside a
  /// node (a position in a long string literal). The default reports each
  /// [check] finding at the start of its node.
  void checkAt(
    CompilationUnit unit,
    void Function(int offset, String message) report,
  ) => check(unit, (node, message) => report(node.offset, message));
}

/// `import 'dart:mirrors'` breaks AOT compilation (ADR: zero reflection).
final class NoDartMirrors extends LintRule {
  /// `no_dart_mirrors`: Daravel compiles ahead of time, without reflection.
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
  /// `no_print_in_app`: application code logs through `Log`.
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
  /// `no_mutable_static_in_app`: static state is not shared between isolates.
  const NoMutableStaticInApp();

  @override
  String get name => 'no_mutable_static_in_app';

  @override
  String get description =>
      'Static fields in lib/app must be final or const, and not collect '
      'state in a collection.';

  @override
  bool appliesTo(String relativePath) => relativePath.startsWith('lib/app/');

  /// Where the state belongs instead: each isolate (`APP_ISOLATES` > 1) and
  /// each server has its own copy of a static.
  static const String replacement =
      'With APP_ISOLATES > 1 each isolate has its own copy. Keep shared '
      "state in a shared store: Cache.store('process') (one machine) or "
      'Redis (several), RateLimiter for counters and limits, '
      'Auth.jwtGuard().invalidate() for revoked tokens, or the container '
      'for per-request services.';

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    void inspect(VariableDeclarationList list, String kind) {
      if (list.isConst) {
        return;
      }
      for (final variable in list.variables) {
        final label = '$kind `${variable.name.lexeme}`';
        if (!list.isFinal) {
          report(variable, '$label is mutable state. $replacement');
        } else if (_emptyMutableCollection(variable.initializer)) {
          report(
            variable,
            '$label is final but starts as an empty collection that '
            'collects state. $replacement',
          );
        }
      }
    }

    unit.accept(
      _Visitor(
        onField: (node) {
          if (node.isStatic) {
            inspect(node.fields, 'Static field');
          }
        },
        onTopLevel: (node) => inspect(node.variables, 'Top-level variable'),
      ),
    );
  }

  /// `{}`, `[]`, `<K, V>{}`, `Map()`, `<T>[]` without `const`: a lookup
  /// table with entries stays allowed.
  static bool _emptyMutableCollection(Expression? initializer) =>
      switch (initializer) {
        SetOrMapLiteral(:final constKeyword, :final elements) =>
          constKeyword == null && elements.isEmpty,
        ListLiteral(:final constKeyword, :final elements) =>
          constKeyword == null && elements.isEmpty,
        InstanceCreationExpression(:final keyword, :final constructorName) =>
          keyword?.lexeme != 'const' &&
              _collectionTypes.contains(constructorName.type.name.lexeme),
        MethodInvocation(:final methodName, :final target) =>
          target == null && _collectionTypes.contains(methodName.name),
        _ => false,
      };

  static const Set<String> _collectionTypes = <String>{
    'Map',
    'Set',
    'List',
    'HashMap',
    'HashSet',
    'LinkedHashMap',
    'LinkedHashSet',
    'Queue',
    'ListQueue',
  };
}

/// String interpolation into raw SQL is an injection risk; pass bindings.
final class NoSqlStringInterpolation extends LintRule {
  /// `no_sql_string_interpolation`: values go in bindings, never in the SQL.
  const NoSqlStringInterpolation();

  /// The methods taking raw SQL.
  static const Set<String> sqlMethods = <String>{
    ...genericSqlMethods,
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

  /// Names common outside SQL (a model's own `raw('column')`, a UI
  /// `select(...)`): they count only on a database receiver, that is `DB`,
  /// a variable named like a connection or query builder, or a builder
  /// chain (`DB.table('t')`, `User.query()`).
  static const Set<String> genericSqlMethods = <String>{
    'select',
    'statement',
    'insertGetId',
    'raw',
  };

  static final RegExp _dbReceiverName = RegExp(
    r'^(db|database|conn|connection|query|builder|qb|q|schema)$|'
    r'(Query|Builder|Connection|Db|DB)$',
  );

  static const Set<String> _builderMethods = <String>{
    'table',
    'query',
    'newQuery',
    'connection',
    'from',
    'select',
    'join',
    'leftJoin',
    'orderBy',
    'groupBy',
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
    final constants = <String>{};
    unit.accept(_ConstCollector(constants));
    void inspect(AstNode node, String callee, NodeList<Argument> arguments) {
      if (arguments.isEmpty) {
        return;
      }
      final sql = arguments.first.argumentExpression;
      if (_interpolates(sql, constants)) {
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
          final method = node.methodName.name;
          if (sqlMethods.contains(method) &&
              (!genericSqlMethods.contains(method) ||
                  _isDbReceiver(node.realTarget))) {
            inspect(node, method, node.argumentList.arguments);
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

  /// Whether [target] looks like the database: `DB`, a variable named like
  /// a connection or builder, or a chain that starts or continues a query.
  static bool _isDbReceiver(Expression? target) => switch (target) {
    null => false,
    SimpleIdentifier(:final name) => _dbReceiverName.hasMatch(name),
    PrefixedIdentifier(:final identifier) => _isDbReceiver(identifier),
    PropertyAccess(:final propertyName) => _isDbReceiver(propertyName),
    MethodInvocation(:final methodName, :final realTarget) =>
      _builderMethods.contains(methodName.name) ||
          methodName.name.startsWith('where') ||
          _isDbReceiver(realTarget),
    ParenthesizedExpression(:final expression) => _isDbReceiver(expression),
    AwaitExpression(:final expression) => _isDbReceiver(expression),
    _ => false,
  };

  /// Literals and `const` names declared in this file: SQL built only from
  /// them is compile-time text and cannot carry input.
  static bool _isConstant(Expression expression, Set<String> constants) =>
      switch (expression) {
        StringLiteral() => !_interpolates(expression, constants),
        IntegerLiteral() || DoubleLiteral() || BooleanLiteral() => true,
        SimpleIdentifier(:final name) => constants.contains(name),
        PrefixedIdentifier(:final identifier) => constants.contains(
          identifier.name,
        ),
        ParenthesizedExpression(:final expression) => _isConstant(
          expression,
          constants,
        ),
        _ => false,
      };

  static bool _interpolates(Expression expression, Set<String> constants) =>
      switch (expression) {
        StringInterpolation(:final elements) =>
          elements.whereType<InterpolationExpression>().any(
            (element) => !_isConstant(element.expression, constants),
          ),
        AdjacentStrings(:final strings) => strings.any(
          (string) => _interpolates(string, constants),
        ),
        BinaryExpression(
          :final operator,
          :final leftOperand,
          :final rightOperand,
        ) =>
          operator.type == TokenType.PLUS &&
              ((leftOperand is StringLiteral ||
                          rightOperand is StringLiteral) &&
                      !(_isConstant(leftOperand, constants) &&
                          _isConstant(rightOperand, constants)) ||
                  _interpolates(leftOperand, constants) ||
                  _interpolates(rightOperand, constants)),
        ParenthesizedExpression(:final expression) => _interpolates(
          expression,
          constants,
        ),
        _ => false,
      };
}

/// Collects the names of `const` variables (top level, static, local).
final class _ConstCollector extends RecursiveAstVisitor<void> {
  _ConstCollector(this.names);

  final Set<String> names;

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    if (node.isConst) {
      for (final variable in node.variables) {
        names.add(variable.name.lexeme);
      }
    }
    super.visitVariableDeclarationList(node);
  }
}

/// `orderBy(request.query('sort'))`: a column name that is not written in
/// the code goes into the SQL text. The grammar quotes it and rejects odd
/// characters, but any existing column (`password`) still passes. This
/// reports column arguments of query builder methods that are neither a
/// string literal, a `const`, nor a `SqlIdentifier` (a name checked when it
/// is made), so a project can require every such name to go through one.
///
/// Opt-in: not part of [defaultRules]. Enable it with
/// `lintProject(root, rules: rulesWith(['prefer_sql_identifier']))`
/// or, in a test, `expectLintClean(null, ['prefer_sql_identifier'])`.
final class PreferSqlIdentifier extends LintRule {
  /// `prefer_sql_identifier`: computed column names are [SqlIdentifier]s.
  const PreferSqlIdentifier();

  /// Builder methods and the positions of their column arguments.
  static const Map<String, List<int>> columnArguments = <String, List<int>>{
    'where': [0],
    'orWhere': [0],
    'whereIn': [0],
    'whereNotIn': [0],
    'orWhereIn': [0],
    'whereNull': [0],
    'whereNotNull': [0],
    'orWhereNull': [0],
    'whereBetween': [0],
    'whereNotBetween': [0],
    'whereLike': [0],
    'whereDate': [0],
    'whereYear': [0],
    'whereMonth': [0],
    'whereDay': [0],
    'whereJsonContains': [0],
    'whereJsonLength': [0],
    'whereColumn': [0, 2],
    'having': [0],
    'orHaving': [0],
    'orderBy': [0],
    'orderByDesc': [0],
    'latest': [0],
    'oldest': [0],
    'pluck': [0, 1],
    'sum': [0],
    'avg': [0],
    'min': [0],
    'max': [0],
    'increment': [0],
    'decrement': [0],
    // A list of columns.
    'select': [0],
    'addSelect': [0],
    'groupBy': [0],
    'whereAny': [0],
    'whereAll': [0],
    'whereNone': [0],
  };

  @override
  String get name => 'prefer_sql_identifier';

  @override
  String get description =>
      'Computed column names go through SqlIdentifier (opt-in).';

  /// Application code only, like `no_sql_string_interpolation`.
  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    final constants = <String>{};
    unit.accept(_ConstCollector(constants));
    final identifiers = <String>{};
    unit.accept(_SqlIdentifierCollector(identifiers));
    void inspect(Expression column, String method) {
      if (column is ListLiteral) {
        for (final element in column.elements) {
          if (element is Expression) {
            inspect(element, method);
          }
        }
        return;
      }
      if (!_accepted(column, constants, identifiers)) {
        report(
          column,
          'Column passed to $method is computed; make it a '
          'SqlIdentifier(...) (or check it against a list of allowed columns).',
        );
      }
    }

    unit.accept(
      _Visitor(
        onMethod: (node) {
          final method = node.methodName.name;
          final positions = columnArguments[method];
          if (positions == null ||
              !NoSqlStringInterpolation._isDbReceiver(node.realTarget)) {
            return;
          }
          final positional = node.argumentList.arguments
              .where((a) => a is! NamedArgument)
              .map((a) => a.argumentExpression)
              .toList();
          for (final position in positions) {
            if (position < positional.length) {
              inspect(positional[position], method);
            }
          }
        },
      ),
    );
  }

  static bool _accepted(
    Expression column,
    Set<String> constants,
    Set<String> identifiers,
  ) => switch (column) {
    ParenthesizedExpression(:final expression) => _accepted(
      expression,
      constants,
      identifiers,
    ),
    // Closures (`where((q) {...})`), maps (`where({...})`) and raw SQL,
    // which `no_sql_string_interpolation` checks.
    FunctionExpression() || SetOrMapLiteral() || NullLiteral() => true,
    MethodInvocation(:final methodName, :final target) =>
      _isSqlIdentifier(methodName.name, target) ||
          methodName.name == 'raw' ||
          methodName.name == 'RawExpression',
    InstanceCreationExpression(:final constructorName) => const {
      'SqlIdentifier',
      'RawExpression',
    }.contains(constructorName.type.name.lexeme),
    PostfixExpression(:final operand) => _accepted(
      operand,
      constants,
      identifiers,
    ),
    // A choice between accepted names is a whitelist:
    // `sort == 'name' ? 'name' : 'id'`, `switch (sort) {...}`.
    ConditionalExpression(:final thenExpression, :final elseExpression) =>
      _accepted(thenExpression, constants, identifiers) &&
          _accepted(elseExpression, constants, identifiers),
    SwitchExpression(:final cases) => cases.every(
      (c) => _accepted(c.expression, constants, identifiers),
    ),
    SimpleIdentifier(:final name) =>
      constants.contains(name) || identifiers.contains(name),
    PrefixedIdentifier(:final identifier) =>
      constants.contains(identifier.name) ||
          identifiers.contains(identifier.name),
    PropertyAccess(:final propertyName) =>
      constants.contains(propertyName.name) ||
          identifiers.contains(propertyName.name),
    _ => NoSqlStringInterpolation._isConstant(column, constants),
  };

  /// `SqlIdentifier(x)` or `SqlIdentifier.tryParse(x)`.
  static bool _isSqlIdentifier(String method, Expression? target) =>
      (target == null && method == 'SqlIdentifier') ||
      (target is SimpleIdentifier &&
          target.name == 'SqlIdentifier' &&
          method == 'tryParse');
}

/// Collects the names of variables, fields and parameters that hold a
/// `SqlIdentifier`: typed so, or initialized with `SqlIdentifier(...)`.
final class _SqlIdentifierCollector extends RecursiveAstVisitor<void> {
  _SqlIdentifierCollector(this.names);

  final Set<String> names;

  static bool _typed(TypeAnnotation? type) =>
      type is NamedType && type.name.lexeme == 'SqlIdentifier';

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    for (final variable in node.variables) {
      final initializer = variable.initializer;
      if (_typed(node.type) ||
          ((node.isFinal || node.isConst) &&
              initializer != null &&
              PreferSqlIdentifier._accepted(initializer, const {}, names))) {
        names.add(variable.name.lexeme);
      }
    }
    super.visitVariableDeclarationList(node);
  }

  @override
  void visitRegularFormalParameter(RegularFormalParameter node) {
    final name = node.name;
    if (name != null && _typed(node.type)) {
      names.add(name.lexeme);
    }
    super.visitRegularFormalParameter(node);
  }
}

/// Validation rule strings (`'required|emial|max:255'`) are parsed when
/// the route or request is defined; this reports unknown names and missing
/// or malformed arguments before that, in `.rules({...})`,
/// `.validate({...})`, `Validator(data, {...})` and `FormRequest.rules()`.
final class InvalidValidationRule extends LintRule {
  /// `invalid_validation_rule`: unknown rules and wrong arguments in rule
  /// strings.
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
    'accepted',
    'accepted_if',
    'declined',
    'declined_if',
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
    'gt',
    'gte',
    'lt',
    'lte',
    'decimal',
    'multiple_of',
    'min_digits',
    'max_digits',
    'date_equals',
    'timezone',
    'required_with_all',
    'required_without_all',
    'required_if_accepted',
    'present_if',
    'prohibited_if',
    'prohibited_unless',
    'prohibits',
    'exclude',
    'exclude_if',
    'exclude_unless',
    'exclude_with',
    'exclude_without',
    'in',
    'not_in',
    'distinct',
    'confirmed',
    'same',
    'different',
    'starts_with',
    'ends_with',
    'date',
    'date_format',
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
    'accepted_if': 2,
    'declined_if': 2,
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

  /// The rules whose arguments must be integers.
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
  /// `unawaited_in_db_transaction`: a query not awaited runs outside the
  /// transaction.
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

/// `ScheduledTask.timezone('Asia/Jakarta')`: the zone name must exist in the
/// IANA database, or the application fails at boot.
final class InvalidTimezone extends LintRule {
  /// `invalid_timezone`: time zone names must exist.
  const InvalidTimezone();

  @override
  String get name => 'invalid_timezone';

  @override
  String get description => 'Scheduler zone names must be IANA zones.';

  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  static Map<String, String>? _zones;

  /// Known zone names by their lower-case form.
  static Map<String, String> get zones => _zones ??= () {
    tzdata.initializeTimeZones();
    return {
      for (final name in tz.timeZoneDatabase.locations.keys)
        name.toLowerCase(): name,
    };
  }();

  /// The problem with [zone], or `null` when it is a known zone.
  static String? problemIn(String zone) {
    final known = zones[zone.toLowerCase()];
    if (known == zone) {
      return null;
    }
    return known == null
        ? 'Unknown time zone "$zone"; use an IANA name such as '
              '"Asia/Jakarta" or "America/New_York".'
        : 'Unknown time zone "$zone"; did you mean "$known"?';
  }

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    unit.accept(
      _Visitor(
        onMethod: (node) {
          final arguments = node.argumentList.arguments;
          if (node.methodName.name != 'timezone' || arguments.length != 1) {
            return;
          }
          final argument = arguments.first.argumentExpression;
          final zone = InvalidValidationRule._literalText(argument);
          final problem = zone == null ? null : problemIn(zone);
          if (problem != null) {
            report(argument, problem);
          }
        },
      ),
    );
  }
}

/// An interpolated value inside an inline event handler of generated HTML:
/// `'<button onclick="join(\'${m.name}\')">'`, or the same with a
/// JavaScript template value (`\${m.name}`) in a page's script.
///
/// HTML escaping does not make this safe: the browser decodes the entities
/// in an attribute (`&#39;` back to `'`) before it parses the attribute as
/// JavaScript, so a quote in the value still ends the JS string and the
/// rest runs as code. Put the value in a `data-*` attribute, or keep it in
/// the script, and bind the handler with `addEventListener`.
///
/// Each string literal is read on its own: adjacent literals (`'a' 'b'`)
/// and concatenation are not joined, so an attribute split across a
/// literal boundary is not detected.
final class NoInlineJsInterpolation extends LintRule {
  /// `no_inline_js_interpolation`: no values in `on*=` attributes.
  const NoInlineJsInterpolation();

  @override
  String get name => 'no_inline_js_interpolation';

  @override
  String get description =>
      'No interpolated values inside inline on* event handler attributes.';

  @override
  bool appliesTo(String relativePath) => !relativePath.startsWith('lib/src/');

  /// What the finding says.
  static const String message =
      'Interpolated value inside an inline on* handler: the browser decodes '
      'HTML entities before it runs the attribute as JavaScript, so escaping '
      'does not stop a quote from breaking out. Put the value in a data-* '
      'attribute and bind the handler with addEventListener.';

  static final RegExp _handler = RegExp(r'''(?:^|[\s"'/])on[a-zA-Z]+\s*=\s*''');

  /// Stands in for a Dart interpolation in the reconstructed string value.
  static final String _hole = String.fromCharCode(0);

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    unit.accept(
      _StringValueVisitor((node, value, offsets) {
        for (final _ in findIn(value)) {
          report(node, message);
        }
      }),
    );
  }

  @override
  void checkAt(CompilationUnit unit, void Function(int, String) report) {
    unit.accept(
      _StringValueVisitor((node, value, offsets) {
        for (final index in findIn(value)) {
          report(offsets[index], message);
        }
      }),
    );
  }

  /// For each `on*=` attribute in [value] (a string's value, with [_hole]
  /// for each Dart interpolation) that holds an interpolated value, the
  /// index of its first one.
  static Iterable<int> findIn(String value) sync* {
    for (final match in _handler.allMatches(value)) {
      var start = match.end;
      int end;
      if (start < value.length &&
          (value[start] == '"' || value[start] == "'")) {
        final close = value.indexOf(value[start], start + 1);
        start++;
        end = close == -1 ? value.length : close;
      } else {
        end = start;
        while (end < value.length &&
            value[end].trim().isNotEmpty &&
            value[end] != '>') {
          end++;
        }
      }
      final attribute = value.substring(start, end);
      final hole = attribute.indexOf(_hole);
      final template = attribute.indexOf(r'${');
      final first = hole == -1
          ? template
          : template == -1
          ? hole
          : (hole < template ? hole : template);
      if (first != -1) {
        yield start + first;
      }
    }
  }
}

/// Calls [onString] with each string literal's value (escapes decoded, a
/// NUL for every interpolation) and the source offset of each character.
final class _StringValueVisitor extends RecursiveAstVisitor<void> {
  _StringValueVisitor(this.onString);

  final void Function(AstNode node, String value, List<int> offsets) onString;

  static const int _backslash = 0x5C;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    final text = StringBuffer();
    final offsets = <int>[];
    _cook(
      node.literal,
      node.contentsOffset,
      node.contentsEnd,
      node.isRaw,
      text,
      offsets,
    );
    onString(node, text.toString(), offsets);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    final text = StringBuffer();
    final offsets = <int>[];
    for (final element in node.elements) {
      switch (element) {
        case InterpolationString():
          _cook(
            element.contents,
            element.contentsOffset,
            element.contentsEnd,
            node.isRaw,
            text,
            offsets,
          );
        case InterpolationExpression():
          text.write(NoInlineJsInterpolation._hole);
          offsets.add(element.offset);
      }
    }
    onString(node, text.toString(), offsets);
    super.visitStringInterpolation(node);
  }

  /// Appends the value of [token]'s characters from [start] to [end]
  /// (source offsets) to [text], with each character's offset.
  static void _cook(
    Token token,
    int start,
    int end,
    bool raw,
    StringBuffer text,
    List<int> offsets,
  ) {
    final lexeme = token.lexeme;
    var i = start - token.offset;
    final stop = end - token.offset;
    while (i < stop) {
      final at = token.offset + i;
      final unit = lexeme.codeUnitAt(i);
      if (raw || unit != _backslash || i + 1 >= stop) {
        text.writeCharCode(unit);
        offsets.add(at);
        i++;
        continue;
      }
      final next = lexeme[i + 1];
      i += 2;
      int? code;
      switch (next) {
        case 'n':
          code = 0x0A;
        case 'r':
          code = 0x0D;
        case 't':
          code = 0x09;
        case 'b':
          code = 0x08;
        case 'f':
          code = 0x0C;
        case 'v':
          code = 0x0B;
        case 'x' when i + 2 <= stop:
          code = int.tryParse(lexeme.substring(i, i + 2), radix: 16);
          i += 2;
        case 'u' when i < stop && lexeme[i] == '{':
          final close = lexeme.indexOf('}', i);
          final digits = close == -1 ? '' : lexeme.substring(i + 1, close);
          code = int.tryParse(digits, radix: 16);
          i = close == -1 ? stop : close + 1;
        case 'u' when i + 4 <= stop:
          code = int.tryParse(lexeme.substring(i, i + 4), radix: 16);
          i += 4;
        default:
          code = next.codeUnitAt(0);
      }
      final char = code ?? 0xFFFD;
      text.writeCharCode(char);
      offsets.add(at);
      if (char > 0xFFFF) {
        offsets.add(at); // the surrogate pair's second unit
      }
    }
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
  InvalidTimezone(),
  NoInlineJsInterpolation(),
];

/// Opt-in rules: not run unless enabled by name ([rulesWith]) or passed in
/// `rules:`.
const List<LintRule> optionalRules = <LintRule>[PreferSqlIdentifier()];

/// [defaultRules] plus the [optionalRules] named in [enable]
/// (`['prefer_sql_identifier']`); an unknown name throws an [ArgumentError].
List<LintRule> rulesWith(Iterable<String> enable) {
  final byName = {for (final rule in optionalRules) rule.name: rule};
  return <LintRule>[
    ...defaultRules,
    for (final name in enable.toSet())
      byName[name] ??
          (throw ArgumentError.value(
            name,
            'enable',
            'Not an opt-in rule (${byName.keys.join(', ')})',
          )),
  ];
}

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
    rule.checkAt(parsed.unit, (offset, message) {
      final location = parsed.lineInfo.getLocation(offset);
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

/// Convention folders checked only when their registry exists: projects
/// created before `bootstrap/models.dart` (1.3) have no model registry.
const Map<String, String> optionalRegistryConventions = <String, String>{
  'lib/app/models': 'bootstrap/models.dart',
};

/// `registry_entry_missing`: classes in convention folders that no registry
/// imports (they would silently never run — ADR-002).
///
/// In [calledThrough] folders (seeders), a file also counts as registered
/// when a registered file of the same folder imports it, directly or
/// through others: a `DatabaseSeeder` that runs `CandidateSeeder` itself,
/// as Laravel's `$this->call()` does, needs only the root seeder in the
/// registry. Elsewhere an import is not enough: a job needs its
/// `JobDefinition` and a model its entry even when another one imports it.
List<LintIssue> checkRegistries(
  String root, {
  Map<String, String> conventions = registryConventions,
  Map<String, String> optional = optionalRegistryConventions,
  Set<String> calledThrough = const {'database/seeders'},
}) {
  final issues = <LintIssue>[];
  for (final entry in [
    ...conventions.entries,
    ...optional.entries.where((e) => File(p.join(root, e.value)).existsSync()),
  ]) {
    final dir = Directory(p.join(root, entry.key));
    final registry = File(p.join(root, entry.value));
    if (!dir.existsSync()) {
      continue;
    }
    final registered = registry.existsSync() ? registry.readAsStringSync() : '';
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    final sources = {
      for (final f in files) p.basename(f.path): f.readAsStringSync(),
    };
    bool imports(String source, String name) =>
        RegExp('[\'"](?:\\./|[^\'"]*/)?${RegExp.escape(name)}[\'"]')
            .hasMatch(source);
    final reached = {
      for (final name in sources.keys)
        if (registered.contains('/$name\'')) name,
    };
    // Seeders a reached seeder imports run through it.
    final queue = calledThrough.contains(entry.key) ? [...reached] : <String>[];
    while (queue.isNotEmpty) {
      final source = sources[queue.removeLast()]!;
      for (final name in sources.keys) {
        if (!reached.contains(name) && imports(source, name)) {
          reached.add(name);
          queue.add(name);
        }
      }
    }
    for (final file in files) {
      final name = p.basename(file.path);
      if (!reached.contains(name)) {
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
