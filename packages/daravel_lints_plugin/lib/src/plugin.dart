import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;

import 'fix.dart';
import 'model_index.dart';

/// The Daravel lint rules as a Dart analysis server plugin: the rules of
/// `dartisan lint` reported in the editor (and by `dart analyze`) as they
/// are typed. The rules themselves live in `package:daravel_lints`; this
/// package only runs them for the analysis server.
///
/// The rules `dartisan lint` runs by default are registered as warning
/// rules (on once the plugin is enabled); the opt-in ones as lint rules,
/// enabled under `plugins: daravel_lints_plugin: diagnostics:`. So is
/// `string_column_name`, which reads the models of the package each file
/// is in ([ModelIndexCache]).
final class DaravelLintsPlugin extends Plugin {
  /// The plugin; `lib/main.dart` exposes it as `plugin`.
  DaravelLintsPlugin({
    this.warnings = defaultRules,
    this.lints = optionalRules,
  });

  /// The rules on once the plugin is enabled (`dartisan lint`'s defaults).
  final List<LintRule> warnings;

  /// The opt-in rules, enabled under `diagnostics:`.
  final List<LintRule> lints;

  @override
  String get name => 'Daravel lints';

  @override
  void register(PluginRegistry registry) {
    for (final rule in warnings) {
      final analysisRule = DaravelAnalysisRule(rule);
      registry.registerWarningRule(analysisRule);
      _registerFix(registry, analysisRule);
    }
    for (final analysisRule in [
      for (final rule in lints) DaravelAnalysisRule(rule),
      DaravelAnalysisRule.stringColumnName(),
    ]) {
      registry.registerLintRule(analysisRule);
      _registerFix(registry, analysisRule);
    }
  }

  /// The quick fix of every rule: offered where the rule's
  /// [LintRule.fixFor] gives one (`string_validation_rule`,
  /// `string_column_name`), nothing elsewhere.
  static void _registerFix(
    PluginRegistry registry,
    DaravelAnalysisRule analysisRule,
  ) => registry.registerFixForRule(
    analysisRule.diagnosticCode,
    ({required context}) => DaravelFix(
      analysisRule.rule,
      ruleIn: analysisRule.ruleIn,
      context: context,
    ),
  );
}

/// A `daravel_lints` [LintRule] as an analysis server rule. Each finding is
/// reported where the rule points, with the rule's own message, unless its
/// line carries `// daravel-lint-ignore: <rule>` (as `dartisan lint`) or
/// the analyzer's `// ignore: <rule>`.
final class DaravelAnalysisRule extends AnalysisRule {
  /// The analysis server rule for [rule]; [ruleIn] builds the rule run on
  /// one file, for a rule that depends on the file's package.
  DaravelAnalysisRule(this.rule, {this.ruleIn})
    : super(name: rule.name, description: rule.description);

  /// `string_column_name` over the models of each file's package, from
  /// [cache] (one per isolate by default).
  factory DaravelAnalysisRule.stringColumnName([ModelIndexCache? cache]) {
    final models = cache ?? _models;
    return DaravelAnalysisRule(
      StringColumnName(ModelColumnIndex(const {})),
      ruleIn: (file, unit) => StringColumnName(models.indexFor(file, unit)),
    );
  }

  static final ModelIndexCache _models = ModelIndexCache();

  /// The `daravel_lints` rule run (its name and description; [ruleIn]
  /// builds the one run on a file when set).
  final LintRule rule;

  /// The rule run on a file, when it depends on the file's package.
  final LintRule Function(File file, CompilationUnit unit)? ruleIn;

  // One code per rule name, kept for the life of the isolate: the analysis
  // server matches codes by identity (and `// ignore:` relies on it).
  static final Map<String, LintCode> _codes = {};

  @override
  LintCode get diagnosticCode =>
      _codes[rule.name] ??= LintCode(rule.name, '{0}');

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _Visitor(this, context));
  }
}

final class _Visitor extends SimpleAstVisitor<void> {
  _Visitor(this.analysisRule, this.context);

  final DaravelAnalysisRule analysisRule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final unit = context.currentUnit;
    if (unit == null) {
      return;
    }
    final root = context.package?.root.path;
    final relative = root == null
        ? unit.file.path
        : p.relative(unit.file.path, from: root);
    final rule =
        analysisRule.ruleIn?.call(unit.file, node) ?? analysisRule.rule;
    if (!rule.appliesTo(relative.replaceAll(r'\', '/'))) {
      return;
    }
    final lines = unit.content.split('\n');
    final ignored = RegExp(
      'daravel-lint-ignore:[^\\n]*\\b${RegExp.escape(rule.name)}\\b',
    );
    // The node each finding of check() names, by offset and message, so the
    // squiggle covers that node; a finding check() does not name (one that
    // points inside a node, through checkAt) covers its token.
    final nodes = <(int, String), AstNode>{};
    rule.check(
      node,
      (found, message) => nodes[(found.offset, message)] ??= found,
    );
    rule.checkAt(node, (offset, message) {
      final line = node.lineInfo.getLocation(offset).lineNumber - 1;
      if (line >= 0 && line < lines.length && ignored.hasMatch(lines[line])) {
        return;
      }
      final found = nodes[(offset, message)];
      final length = found != null ? found.length : _tokenLength(node, offset);
      analysisRule.reportAtOffset(offset, length, arguments: [message]);
    });
  }

  /// The length from [offset] to the end of the token that holds it.
  static int _tokenLength(CompilationUnit unit, int offset) {
    for (Token? t = unit.beginToken; t != null && !t.isEof; t = t.next) {
      if (t.offset <= offset && offset < t.end) {
        return t.end - offset;
      }
      if (t.offset > offset) {
        break;
      }
    }
    return 1;
  }
}
