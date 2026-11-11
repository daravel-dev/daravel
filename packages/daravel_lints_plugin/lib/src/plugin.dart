import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;

/// The Daravel lint rules as a Dart analysis server plugin: the rules of
/// `dartisan lint` reported in the editor (and by `dart analyze`) as they
/// are typed. The rules themselves live in `package:daravel_lints`; this
/// package only runs them for the analysis server.
///
/// The rules `dartisan lint` runs by default are registered as warning
/// rules (on once the plugin is enabled); the opt-in ones as lint rules,
/// enabled under `plugins: daravel_lints_plugin: diagnostics:`.
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
      registry.registerWarningRule(DaravelAnalysisRule(rule));
    }
    for (final rule in lints) {
      registry.registerLintRule(DaravelAnalysisRule(rule));
    }
  }
}

/// A `daravel_lints` [LintRule] as an analysis server rule. Each finding is
/// reported where the rule points, with the rule's own message, unless its
/// line carries `// daravel-lint-ignore: <rule>` (as `dartisan lint`) or
/// the analyzer's `// ignore: <rule>`.
final class DaravelAnalysisRule extends AnalysisRule {
  /// The analysis server rule for [rule].
  DaravelAnalysisRule(this.rule)
    : super(name: rule.name, description: rule.description);

  /// The `daravel_lints` rule run.
  final LintRule rule;

  /// `// daravel-lint-ignore: <rule>` (other rules may share the comment).
  late final RegExp ignored = RegExp(
    'daravel-lint-ignore:[^\\n]*\\b${RegExp.escape(rule.name)}\\b',
  );

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
    final rule = analysisRule.rule;
    if (!rule.appliesTo(relative.replaceAll(r'\', '/'))) {
      return;
    }
    final content = unit.content;
    void report(int offset, int length, String message) {
      if (!_ignored(content, node.lineInfo, offset)) {
        analysisRule.reportAtOffset(offset, length, arguments: [message]);
      }
    }

    if (!rule.reportsInsideNodes) {
      // checkAt would only repeat check's walk: one walk, each finding's
      // squiggle covering the node it names.
      rule.check(
        node,
        (found, message) => report(found.offset, found.length, message),
      );
      return;
    }
    // The node each finding of check() names, by offset and message, so the
    // squiggle covers that node; a finding check() does not name (one that
    // points inside a node, through checkAt) covers its token.
    final nodes = <(int, String), AstNode>{};
    rule.check(
      node,
      (found, message) => nodes[(found.offset, message)] ??= found,
    );
    rule.checkAt(node, (offset, message) {
      final found = nodes[(offset, message)];
      final length = found != null ? found.length : _tokenLength(node, offset);
      report(offset, length, message);
    });
  }

  /// Whether the line holding [offset] carries
  /// `daravel-lint-ignore: <rule>`; reads that line only, not every line.
  bool _ignored(String content, LineInfo lineInfo, int offset) {
    if (offset < 0 || offset > content.length) {
      return false;
    }
    final line = lineInfo.getLocation(offset).lineNumber - 1;
    final start = lineInfo.getOffsetOfLine(line);
    final end = content.indexOf('\n', start);
    return analysisRule.ignored.hasMatch(
      content.substring(start, end == -1 ? content.length : end),
    );
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
