import 'package:daravel/daravel.dart';

import 'config.dart';
import 'jobs.dart';

/// `withMediaLibrary()` on the application builder.
extension MediaLibraryApplicationBuilder on ApplicationBuilder {
  /// Reads the `MEDIA_*` settings ([MediaLibraryConfig]) and registers
  /// [PerformConversionsJob]. Add `CreateMediaTable()` to
  /// `bootstrap/migrations.dart`, and the models that have media to
  /// `withModels(...)` so queued conversions can load them.
  ApplicationBuilder withMediaLibrary() =>
      withConfig<MediaLibraryConfig>(MediaLibraryConfig.fromEnv)
          .withProviders([_MediaLibraryProvider()]);
}

final class _MediaLibraryProvider extends ServiceProvider {
  @override
  void boot(Container container) {
    // Into the registry, not withJobs(): that would replace the
    // application's own `configure` callback.
    if (container.bound<JobRegistry>()) {
      container.make<JobRegistry>().register(PerformConversionsJob.definition);
    }
  }
}
