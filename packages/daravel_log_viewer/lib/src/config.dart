import 'package:daravel/daravel.dart';

/// The `LOG_VIEWER_*` settings.
final class LogViewerConfig implements ConfigSection {
  const LogViewerConfig({
    this.enabled = true,
    this.path = '/log-viewer',
    this.directory,
    this.perPage = 50,
    this.allowDownload = true,
    this.allowDelete = false,
    this.maskKeys = defaultMaskKeys,
    this.maxScanBytes = 64 * 1024 * 1024,
  });

  factory LogViewerConfig.fromEnv(Env env) {
    final directory = env.maybeString('LOG_VIEWER_DIRECTORY');
    return LogViewerConfig(
      enabled: env.boolean('LOG_VIEWER_ENABLED', true),
      path: env.string('LOG_VIEWER_PATH', '/log-viewer'),
      directory: directory == null || directory.isEmpty ? null : directory,
      perPage: env.integer('LOG_VIEWER_PER_PAGE', 50).clamp(1, 500),
      allowDownload: env.boolean('LOG_VIEWER_ALLOW_DOWNLOAD', true),
      allowDelete: env.boolean('LOG_VIEWER_ALLOW_DELETE', false),
      maskKeys: env.list('LOG_VIEWER_MASK_KEYS', defaultMaskKeys),
      maxScanBytes:
          env.integer('LOG_VIEWER_MAX_SCAN_MB', 64).clamp(1, 4096) *
          1024 *
          1024,
    );
  }

  /// `false` answers 404 on every route (`LOG_VIEWER_ENABLED`).
  final bool enabled;

  /// The page's URL path (`LOG_VIEWER_PATH`), unless `withLogViewer` is
  /// given one.
  final String path;

  /// The folder of the log files (`LOG_VIEWER_DIRECTORY`); the logger's
  /// `LOG_PATH` when null.
  final String? directory;

  /// Entries per page (`LOG_VIEWER_PER_PAGE`, at most 500).
  final int perPage;
  final bool allowDownload;

  /// Deleting a file from the page (`LOG_VIEWER_ALLOW_DELETE`, off).
  final bool allowDelete;

  /// Keys whose values are shown as `********` (substring, ignoring case),
  /// on top of what `LOG_REDACT` removed when the entry was written.
  final List<String> maskKeys;

  /// How much of a file one page reads at most while filtering
  /// (`LOG_VIEWER_MAX_SCAN_MB`); the page then offers to read on.
  final int maxScanBytes;

  static const List<String> defaultMaskKeys = [
    'password',
    'secret',
    'token',
    'authorization',
    'cookie',
    'api_key',
    'app_key',
    'credit_card',
  ];

  @override
  String get key => 'log_viewer';

  @override
  Map<String, Object?> toMap() => {
    'enabled': enabled,
    'path': path,
    'directory': directory,
    'per_page': perPage,
    'allow_download': allowDownload,
    'allow_delete': allowDelete,
    'mask_keys': maskKeys,
    'max_scan_bytes': maxScanBytes,
  };
}
