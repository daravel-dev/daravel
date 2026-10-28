import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// `security:audit [--target=URL] [--format=terminal|json|sarif]
/// [--output=FILE] [--severity=high] [--only=ids] [--json-path=/api/...]`:
/// a black-box audit of a running server ([SecurityAudit]). It exits 1
/// when a finding reaches `--severity`, so CI can gate on it.
final class SecurityAuditCommand extends DaravelCommand {
  SecurityAuditCommand(super.createApp) {
    argParser
      ..addOption('target', help: 'The server to audit; APP_URL by default.')
      ..addOption(
        'format',
        allowed: const ['terminal', 'json', 'sarif'],
        defaultsTo: 'terminal',
        help: 'Report format.',
      )
      ..addOption('output', help: 'Write the report to this file.')
      ..addOption(
        'severity',
        allowed: [for (final s in AuditSeverity.values) s.name],
        defaultsTo: 'high',
        help: 'Exit 1 when a finding is at or above this severity.',
      )
      ..addOption(
        'only',
        help: 'Run these checks only (ids, e.g. 001,003, or names).',
      )
      ..addOption(
        'json-path',
        help: 'A route that reads a JSON body, for the nesting check.',
      )
      ..addOption(
        'timeout',
        defaultsTo: '5',
        help: 'Seconds to wait for each answer.',
      );
  }

  @override
  String get name => 'security:audit';

  @override
  String get description =>
      'Audit a running server for common deployment security mistakes.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    final raw =
        results['target'] as String? ?? app.config.section<AppConfig>().url;
    final target = Uri.tryParse(raw);
    if (target == null || !target.hasScheme || target.host.isEmpty) {
      stderr.writeln('Not a URL: $raw (pass --target=https://...).');
      return 64;
    }
    final seconds = int.tryParse(results['timeout'] as String);
    if (seconds == null || seconds <= 0) {
      stderr.writeln('--timeout must be a positive number of seconds.');
      return 64;
    }
    final only = (results['only'] as String?)
        ?.split(',')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) => RegExp(r'^\d+$').hasMatch(e) ? e.padLeft(3, '0') : e)
        .map((e) => e.startsWith('daravel-sec-') ? e.toUpperCase() : e)
        .toSet();
    final audit = SecurityAudit(
      target,
      timeout: Duration(seconds: seconds),
      jsonPath: results['json-path'] as String?,
    );
    final result = await audit.run(only: only);
    final report = switch (results['format'] as String) {
      'json' => const JsonEncoder.withIndent('  ').convert(auditJson(result)),
      'sarif' => const JsonEncoder.withIndent(
        '  ',
      ).convert(auditSarif(result, version: daravelVersion)),
      _ => renderAudit(
        result,
        color: results['output'] == null && stdout.supportsAnsiEscapes,
      ),
    };
    final output = results['output'] as String?;
    if (output == null) {
      stdout.write(report.endsWith('\n') ? report : '$report\n');
    } else {
      File(output)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(report);
      stdout.writeln('Wrote $output (${result.findings.length} finding(s)).');
    }
    final threshold = AuditSeverity.values.byName(
      results['severity'] as String,
    );
    return result.failsAt(threshold) ? 1 : 0;
  });
}
