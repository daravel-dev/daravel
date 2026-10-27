import 'package:daravel/daravel.dart';

import 'config.dart';

/// `withActivityLog()` on the application builder.
extension ActivityLogApplicationBuilder on ApplicationBuilder {
  /// Reads the `ACTIVITY_LOGGER_*` settings ([ActivityLogConfig]). Add
  /// `CreateActivityLogTable()` to `bootstrap/migrations.dart`, and the
  /// models activities point at to `withModels(...)` so
  /// `Activity.subject()` and `causer()` can load them.
  ApplicationBuilder withActivityLog() =>
      withConfig<ActivityLogConfig>(ActivityLogConfig.fromEnv);
}
