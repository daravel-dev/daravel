import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How bad a finding is; `--severity` fails the audit at or above one.
enum AuditSeverity {
  info,
  low,
  medium,
  high,
  critical;

  /// SARIF's level for it.
  String get sarifLevel => switch (this) {
    critical || high => 'error',
    medium => 'warning',
    low || info => 'note',
  };
}

/// One check of the audit: an id for SARIF and `--only`, what it looks
/// for, and how to fix what it finds.
final class AuditCheck {
  const AuditCheck(this.id, this.name, this.title, this.remedy);

  final String id;
  final String name;
  final String title;
  final String remedy;
}

/// Something a check found on the target.
final class AuditFinding {
  const AuditFinding(this.check, this.severity, this.message, {this.path});

  final AuditCheck check;
  final AuditSeverity severity;
  final String message;

  /// The request path that showed it.
  final String? path;
}

/// A response as the checks see it: status, headers (lower-case names)
/// and the start of the body.
final class ProbeResponse {
  const ProbeResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, List<String>> headers;
  final String body;

  String? header(String name) => headers[name.toLowerCase()]?.firstOrNull;

  List<String> all(String name) => headers[name.toLowerCase()] ?? const [];
}

/// Sends one request to the target and returns its response.
typedef ProbeTransport = Future<ProbeResponse> Function(
  String method,
  String path, {
  Map<String, String> headers,
  List<int>? body,
});

/// The audit's outcome: every check run, what each found, and the checks
/// skipped with the reason.
final class AuditResult {
  AuditResult(this.target, this.checks, this.findings, this.skipped);

  final Uri target;
  final List<AuditCheck> checks;
  final List<AuditFinding> findings;
  final Map<String, String> skipped;

  /// Whether a finding is at or above [threshold].
  bool failsAt(AuditSeverity threshold) =>
      findings.any((f) => f.severity.index >= threshold.index);
}

/// A black-box audit of a running Daravel (or any HTTP) server: single,
/// harmless requests (GET, HEAD, OPTIONS, TRACE and a small POST), no
/// floods and no exploitation, so it can run against a staging server.
///
/// It checks what a deployment gets wrong rather than the framework's
/// internals, which `dart test --tags security` covers: response headers,
/// files a misconfigured proxy or static root would serve, path traversal,
/// TRACE, CRLF injection, stack traces in errors, CORS, cookie flags,
/// `/metrics` and the log viewer left open, and plain HTTP.
final class SecurityAudit {
  SecurityAudit(
    this.target, {
    this._transport,
    this.timeout = const Duration(seconds: 5),
    this.jsonPath,
  });

  final Uri target;
  final Duration timeout;

  /// A route that reads a JSON body, for the nesting check; skipped
  /// without one.
  final String? jsonPath;

  final ProbeTransport? _transport;

  static const securityHeaders = AuditCheck(
    'DARAVEL-SEC-001',
    'SecurityHeaders',
    'Security headers',
    'Add SecurityHeadersMiddleware() to the global middleware in '
        'bootstrap/app.dart (new projects have it).',
  );
  static const serverBanner = AuditCheck(
    'DARAVEL-SEC-002',
    'ServerBanner',
    'Server version disclosure',
    'Remove the version from the Server / X-Powered-By headers at the '
        'proxy (for example `server_tokens off;` in nginx).',
  );
  static const sensitiveFiles = AuditCheck(
    'DARAVEL-SEC-003',
    'SensitiveFiles',
    'Sensitive files served',
    'Serve only the public directory: point the web server or proxy at '
        'public/ (or nothing) instead of the project root, and keep .env, '
        '.git and the database outside it.',
  );
  static const pathTraversal = AuditCheck(
    'DARAVEL-SEC-004',
    'PathTraversal',
    'Path traversal',
    'Serve static files with a server that normalizes paths, or with '
        "Daravel's own static handling, never by joining the raw path.",
  );
  static const traceMethod = AuditCheck(
    'DARAVEL-SEC-005',
    'TraceMethod',
    'TRACE echoes the request',
    'Disable TRACE at the proxy; it echoes headers, cookies included.',
  );
  static const crlfInjection = AuditCheck(
    'DARAVEL-SEC-006',
    'CrlfInjection',
    'Header injection (CRLF)',
    'Never put request input into response headers without removing '
        'carriage returns and line feeds.',
  );
  static const errorDetails = AuditCheck(
    'DARAVEL-SEC-007',
    'ErrorDetails',
    'Errors expose stack traces',
    'Set APP_DEBUG=false (and APP_ENV=production) on the server.',
  );
  static const jsonDepth = AuditCheck(
    'DARAVEL-SEC-008',
    'JsonDepth',
    'Deeply nested JSON',
    'Keep BodyLimitsMiddleware() in the global middleware; it refuses '
        'nesting beyond its maxJsonDepth with 422.',
  );
  static const cors = AuditCheck(
    'DARAVEL-SEC-009',
    'Cors',
    'CORS allows any origin',
    'List the allowed origins in CorsMiddleware(allowedOrigins: [...]) '
        'instead of reflecting the request Origin, especially with '
        'credentials.',
  );
  static const cookieFlags = AuditCheck(
    'DARAVEL-SEC-010',
    'CookieFlags',
    'Cookie flags',
    'Set HttpOnly, SameSite and, over HTTPS, Secure on every cookie.',
  );
  static const exposedMetrics = AuditCheck(
    'DARAVEL-SEC-011',
    'ExposedMetrics',
    '/metrics open to anyone',
    'Set METRICS_TOKEN so /metrics needs `Authorization: Bearer <token>`.',
  );
  static const exposedLogViewer = AuditCheck(
    'DARAVEL-SEC-012',
    'ExposedLogViewer',
    'Log viewer open to anyone',
    "Give it middleware: .withLogViewer(middleware: ['auth', "
        "'can:view-logs']).",
  );
  static const plainHttp = AuditCheck(
    'DARAVEL-SEC-013',
    'PlainHttp',
    'Served over plain HTTP',
    'Serve the application over HTTPS (a proxy such as Caddy, or the '
        "platform's load balancer).",
  );

  static const List<AuditCheck> all = [
    securityHeaders,
    serverBanner,
    sensitiveFiles,
    pathTraversal,
    traceMethod,
    crlfInjection,
    errorDetails,
    jsonDepth,
    cors,
    cookieFlags,
    exposedMetrics,
    exposedLogViewer,
    plainHttp,
  ];

  /// Runs every check, or those whose id or name is in [only].
  Future<AuditResult> run({Set<String>? only}) async {
    final selected = [
      for (final check in all)
        if (only == null ||
            only.contains(check.id) ||
            only.contains(check.name.toLowerCase()) ||
            only.contains(check.id.split('-').last))
          check,
    ];
    final findings = <AuditFinding>[];
    final skipped = <String, String>{};
    final transport = _transport ?? _httpTransport;
    for (final check in selected) {
      try {
        final result = await _runners[check.id]!(this, transport);
        if (result case _Skipped(:final reason)) {
          skipped[check.id] = reason;
        } else if (result case _Found(findings: final found)) {
          findings.addAll(found);
        }
      } on TimeoutException {
        if (check == jsonDepth) {
          findings.add(
            AuditFinding(
              check,
              AuditSeverity.medium,
              'No answer within ${timeout.inSeconds} s to deeply nested JSON.',
              path: jsonPath,
            ),
          );
        } else {
          skipped[check.id] = 'no answer within ${timeout.inSeconds} s';
        }
      } on SocketException catch (error) {
        skipped[check.id] = 'connection failed: ${error.message}';
      } on HttpException catch (error) {
        skipped[check.id] = 'HTTP error: ${error.message}';
      }
    }
    return AuditResult(target, selected, findings, skipped);
  }

  static final Map<
    String,
    Future<_Outcome> Function(SecurityAudit audit, ProbeTransport send)
  >
  _runners = {
    securityHeaders.id: (a, send) => a._securityHeaders(send),
    serverBanner.id: (a, send) => a._serverBanner(send),
    sensitiveFiles.id: (a, send) => a._sensitiveFiles(send),
    pathTraversal.id: (a, send) => a._pathTraversal(send),
    traceMethod.id: (a, send) => a._traceMethod(send),
    crlfInjection.id: (a, send) => a._crlfInjection(send),
    errorDetails.id: (a, send) => a._errorDetails(send),
    jsonDepth.id: (a, send) => a._jsonDepth(send),
    cors.id: (a, send) => a._cors(send),
    cookieFlags.id: (a, send) => a._cookieFlags(send),
    exposedMetrics.id: (a, send) => a._exposedMetrics(send),
    exposedLogViewer.id: (a, send) => a._exposedLogViewer(send),
    plainHttp.id: (a, send) => a._plainHttp(),
  };

  bool get _https => target.scheme == 'https';

  /// The page the header checks read: `/`, else `/up`.
  Future<(String, ProbeResponse)> _page(ProbeTransport send) async {
    final root = await send('GET', '/');
    if (root.status < 400) {
      return ('/', root);
    }
    return ('/up', await send('GET', '/up'));
  }

  Future<_Outcome> _securityHeaders(ProbeTransport send) async {
    final (path, page) = await _page(send);
    AuditFinding found(AuditSeverity severity, String message) =>
        AuditFinding(securityHeaders, severity, message, path: path);
    final html = (page.header('content-type') ?? '').contains('text/html');
    final csp = page.header('content-security-policy') ?? '';
    return _Found([
      if (page.header('x-content-type-options')?.toLowerCase() != 'nosniff')
        found(
          AuditSeverity.medium,
          'X-Content-Type-Options: nosniff is missing.',
        ),
      if (page.header('referrer-policy') == null)
        found(AuditSeverity.low, 'Referrer-Policy is missing.'),
      if (html &&
          page.header('x-frame-options') == null &&
          !csp.contains('frame-ancestors'))
        found(
          AuditSeverity.medium,
          'An HTML page has neither X-Frame-Options nor a CSP '
          'frame-ancestors: it can be framed (clickjacking).',
        ),
      if (_https && page.header('strict-transport-security') == null)
        found(
          AuditSeverity.medium,
          'Strict-Transport-Security is missing on HTTPS.',
        ),
    ]);
  }

  Future<_Outcome> _serverBanner(ProbeTransport send) async {
    final (path, page) = await _page(send);
    final versioned = RegExp(r'\d+\.\d+');
    return _Found([
      for (final name in const ['server', 'x-powered-by'])
        for (final value in page.all(name))
          if (versioned.hasMatch(value))
            AuditFinding(
              serverBanner,
              AuditSeverity.low,
              '$name: $value reveals a version.',
              path: path,
            ),
    ]);
  }

  /// Files that must never be served, and what their content looks like
  /// (so a catch-all route answering 200 with HTML is not a finding).
  static final List<(String, AuditSeverity, RegExp)> _files = [
    ('/.env', AuditSeverity.critical, _envContent),
    ('/.env.production', AuditSeverity.critical, _envContent),
    (
      '/.git/config',
      AuditSeverity.critical,
      RegExp(r'^\[core\]', multiLine: true),
    ),
    ('/.git/HEAD', AuditSeverity.high, RegExp(r'^ref: refs/')),
    (
      '/database/database.sqlite',
      AuditSeverity.critical,
      RegExp('^SQLite format 3'),
    ),
    (
      '/storage/logs/laravel.log',
      AuditSeverity.high,
      RegExp(r'^\[\d{4}-\d\d-\d\d'),
    ),
    (
      '/pubspec.yaml',
      AuditSeverity.low,
      RegExp(r'^dependencies:', multiLine: true),
    ),
    (
      '/pubspec.lock',
      AuditSeverity.low,
      RegExp(r'^packages:', multiLine: true),
    ),
    ('/composer.json', AuditSeverity.low, RegExp(r'"require"\s*:')),
  ];

  static final RegExp _envContent = RegExp(
    r'^(APP_KEY|APP_ENV|DB_PASSWORD|DB_CONNECTION)=',
    multiLine: true,
  );

  Future<_Outcome> _sensitiveFiles(ProbeTransport send) async => _Found([
    for (final (path, severity, content) in _files)
      if (await send('GET', path) case final r
          when r.status == 200 && content.hasMatch(r.body))
        AuditFinding(sensitiveFiles, severity, '$path is served.', path: path),
  ]);

  Future<_Outcome> _pathTraversal(ProbeTransport send) async {
    const paths = [
      '/..%2f.env',
      '/..%2f..%2f.env',
      '/%2e%2e/%2e%2e/.env',
      '/storage/..%2f..%2f.env',
      '/public/..%2f.env',
    ];
    for (final path in paths) {
      final response = await send('GET', path);
      if (response.status == 200 && _envContent.hasMatch(response.body)) {
        return _Found([
          AuditFinding(
            pathTraversal,
            AuditSeverity.critical,
            '$path returns the .env file.',
            path: path,
          ),
        ]);
      }
    }
    return const _Found([]);
  }

  Future<_Outcome> _traceMethod(ProbeTransport send) async {
    final response = await send(
      'TRACE',
      '/',
      headers: const {'x-daravel-audit': 'trace-probe'},
    );
    return _Found([
      if (response.status == 200 && response.body.contains('trace-probe'))
        const AuditFinding(
          traceMethod,
          AuditSeverity.medium,
          'TRACE / answers 200 and echoes the request headers.',
          path: '/',
        ),
    ]);
  }

  Future<_Outcome> _crlfInjection(ProbeTransport send) async {
    const paths = [
      '/%0d%0aX-Daravel-Audit:%20injected',
      '/?next=%0d%0aX-Daravel-Audit:%20injected',
      '/redirect?to=%0d%0aX-Daravel-Audit:%20injected',
    ];
    for (final path in paths) {
      final response = await send('GET', path);
      if (response.header('x-daravel-audit') != null) {
        return _Found([
          AuditFinding(
            crlfInjection,
            AuditSeverity.high,
            '$path puts a header of its own into the response.',
            path: path,
          ),
        ]);
      }
    }
    return const _Found([]);
  }

  /// What a Dart (or PHP) stack trace looks like in a response body.
  static final RegExp _stackTrace = RegExp(
    r'(#\d+\s+\S.*\((package|dart|file):)|(\.dart:\d+:\d+)|'
    r'(Stack trace:)|(\.php:\d+)|(\bat \S+\.php line \d+)',
  );

  Future<_Outcome> _errorDetails(ProbeTransport send) async {
    final probes = <(String, Future<ProbeResponse>)>[
      ('/__daravel_audit_missing__', send('GET', '/__daravel_audit_missing__')),
      (
        '/',
        send(
          'POST',
          '/',
          headers: const {'content-type': 'application/json'},
          body: utf8.encode('{"broken": '),
        ),
      ),
    ];
    if (jsonPath case final path?) {
      probes.add((
        path,
        send(
          'POST',
          path,
          headers: const {'content-type': 'application/json'},
          body: utf8.encode('{"broken": '),
        ),
      ));
    }
    for (final (path, pending) in probes) {
      final response = await pending;
      if (_stackTrace.hasMatch(response.body)) {
        return _Found([
          AuditFinding(
            errorDetails,
            AuditSeverity.high,
            'The ${response.status} answer to $path contains a stack trace.',
            path: path,
          ),
        ]);
      }
    }
    return const _Found([]);
  }

  Future<_Outcome> _jsonDepth(ProbeTransport send) async {
    final path = jsonPath;
    if (path == null) {
      return const _Skipped('pass --json-path=<a route that reads JSON>');
    }
    const depth = 2048;
    final body = '${'[' * depth}1${']' * depth}';
    final response = await send(
      'POST',
      path,
      headers: const {'content-type': 'application/json'},
      body: utf8.encode(body),
    ).timeout(timeout);
    return _Found([
      if (response.status >= 500)
        AuditFinding(
          jsonDepth,
          AuditSeverity.medium,
          'JSON nested $depth levels deep makes $path answer '
          '${response.status}.',
          path: path,
        ),
    ]);
  }

  Future<_Outcome> _cors(ProbeTransport send) async {
    const origin = 'https://daravel-audit.invalid';
    final (path, _) = await _page(send);
    final response = await send('GET', path, headers: const {'origin': origin});
    final allowed = response.header('access-control-allow-origin');
    final credentials =
        response.header('access-control-allow-credentials')?.toLowerCase() ==
        'true';
    return _Found([
      if (allowed == origin)
        AuditFinding(
          cors,
          credentials ? AuditSeverity.high : AuditSeverity.medium,
          'Any Origin is allowed (it is reflected)'
          '${credentials ? ', with credentials' : ''}.',
          path: path,
        )
      else if (allowed == '*' && credentials)
        AuditFinding(
          cors,
          AuditSeverity.high,
          'Access-Control-Allow-Origin: * with credentials.',
          path: path,
        ),
    ]);
  }

  Future<_Outcome> _cookieFlags(ProbeTransport send) async {
    final (path, page) = await _page(send);
    final findings = <AuditFinding>[];
    for (final cookie in page.all('set-cookie')) {
      final name = cookie.split('=').first.trim();
      final flags = cookie.toLowerCase();
      if (!flags.contains('httponly')) {
        findings.add(
          AuditFinding(
            cookieFlags,
            AuditSeverity.medium,
            'Cookie $name has no HttpOnly.',
            path: path,
          ),
        );
      }
      if (_https && !flags.contains('secure')) {
        findings.add(
          AuditFinding(
            cookieFlags,
            AuditSeverity.medium,
            'Cookie $name has no Secure over HTTPS.',
            path: path,
          ),
        );
      }
      if (!flags.contains('samesite')) {
        findings.add(
          AuditFinding(
            cookieFlags,
            AuditSeverity.low,
            'Cookie $name has no SameSite.',
            path: path,
          ),
        );
      }
    }
    return _Found(findings);
  }

  Future<_Outcome> _exposedMetrics(ProbeTransport send) async {
    final response = await send('GET', '/metrics');
    return _Found([
      if (response.status == 200 && response.body.contains('# TYPE '))
        const AuditFinding(
          exposedMetrics,
          AuditSeverity.medium,
          '/metrics answers without a token.',
          path: '/metrics',
        ),
    ]);
  }

  Future<_Outcome> _exposedLogViewer(ProbeTransport send) async {
    const path = '/log-viewer/api/files';
    final response = await send('GET', path);
    return _Found([
      if (response.status == 200 && response.body.contains('"files"'))
        const AuditFinding(
          exposedLogViewer,
          AuditSeverity.high,
          'The log viewer answers without authentication.',
          path: path,
        ),
    ]);
  }

  Future<_Outcome> _plainHttp() async {
    final host = target.host.toLowerCase();
    final local =
        host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.test') ||
        host.endsWith('.ddev.site');
    return _Found([
      if (target.scheme == 'http' && !local)
        AuditFinding(
          plainHttp,
          AuditSeverity.medium,
          '$target is not served over HTTPS.',
        ),
    ]);
  }

  /// Requests over `dart:io`, without following redirects; the body is
  /// read up to 256 KiB.
  Future<ProbeResponse> _httpTransport(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = null;
    try {
      final base = target.toString().replaceFirst(RegExp(r'/+$'), '');
      final request = await client
          .openUrl(method, Uri.parse('$base$path'))
          .timeout(timeout);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final collected = <String, List<String>>{};
      response.headers.forEach((name, values) => collected[name] = values);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length >= 256 * 1024) {
          break;
        }
      }
      return ProbeResponse(
        response.statusCode,
        collected,
        utf8.decode(bytes, allowMalformed: true),
      );
    } finally {
      client.close(force: true);
    }
  }
}

sealed class _Outcome {
  const _Outcome();
}

final class _Found extends _Outcome {
  const _Found(this.findings);
  final List<AuditFinding> findings;
}

final class _Skipped extends _Outcome {
  const _Skipped(this.reason);
  final String reason;
}

/// [result] as text for a terminal; [color] adds ANSI colors.
String renderAudit(AuditResult result, {bool color = false}) {
  String paint(String text, int code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;
  final out = StringBuffer()
    ..writeln('Security audit of ${result.target}')
    ..writeln();
  for (final check in result.checks) {
    final found = result.findings.where((f) => f.check == check).toList();
    final skipped = result.skipped[check.id];
    final status = skipped != null
        ? paint('SKIP', 33)
        : found.isEmpty
        ? paint('PASS', 32)
        : paint('FAIL', 31);
    out.writeln('  $status  ${check.id}  ${check.title}');
    if (skipped != null) {
      out.writeln('        $skipped');
    }
    for (final finding in found) {
      out.writeln('        [${finding.severity.name}] ${finding.message}');
    }
    if (found.isNotEmpty) {
      out.writeln('        Fix: ${check.remedy}');
    }
  }
  final counts = {
    for (final severity in AuditSeverity.values.reversed)
      severity: result.findings.where((f) => f.severity == severity).length,
  }..removeWhere((_, n) => n == 0);
  out
    ..writeln()
    ..writeln(
      counts.isEmpty
          ? 'No findings.'
          : 'Findings: ${[for (final MapEntry(:key, :value) in counts.entries) '$value ${key.name}'].join(', ')}.',
    );
  return out.toString();
}

/// [result] as JSON.
Map<String, Object?> auditJson(AuditResult result) => {
  'target': '${result.target}',
  'checks': [
    for (final check in result.checks)
      {
        'id': check.id,
        'name': check.name,
        'status': result.skipped.containsKey(check.id)
            ? 'skipped'
            : result.findings.any((f) => f.check == check)
            ? 'failed'
            : 'passed',
        'reason': ?result.skipped[check.id],
      },
  ],
  'findings': [
    for (final finding in result.findings)
      {
        'id': finding.check.id,
        'severity': finding.severity.name,
        'message': finding.message,
        'path': ?finding.path,
        'remedy': finding.check.remedy,
      },
  ],
};

/// [result] as SARIF 2.1.0, for GitHub code scanning
/// (`github/codeql-action/upload-sarif`). Findings point at
/// `bootstrap/app.dart`, where most of the fixes go, since a URL is not a
/// file of the repository.
Map<String, Object?> auditSarif(
  AuditResult result, {
  required String version,
}) => {
  r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
  'version': '2.1.0',
  'runs': [
    {
      'tool': {
        'driver': {
          'name': 'dartisan security:audit',
          'version': version,
          'informationUri': 'https://github.com/daravel-dev/daravel/blob/main/docs/guide/security.md',
          'rules': [
            for (final check in result.checks)
              {
                'id': check.id,
                'name': check.name,
                'shortDescription': {'text': check.title},
                'help': {'text': check.remedy},
              },
          ],
        },
      },
      'results': [
        for (final finding in result.findings)
          {
            'ruleId': finding.check.id,
            'level': finding.severity.sarifLevel,
            'message': {
              'text':
                  '${finding.message}'
                  '${finding.path == null ? '' : ' (${result.target.resolve(finding.path!)})'} '
                  '${finding.check.remedy}',
            },
            'locations': [
              {
                'physicalLocation': {
                  'artifactLocation': {'uri': 'bootstrap/app.dart'},
                },
              },
            ],
            'properties': {'severity': finding.severity.name},
          },
      ],
    },
  ],
};
