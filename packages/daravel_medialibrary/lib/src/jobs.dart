import 'package:daravel/daravel.dart';

import 'media.dart';
import 'media_library.dart';

/// Generates queued conversions of one media (Spatie's
/// `PerformConversionsJob`). `withMediaLibrary()` registers it.
final class PerformConversionsJob extends Job {
  /// Generates the conversions of the media with the given id.
  PerformConversionsJob(
    this.mediaId, {
    this.conversions,
    this.onlyMissing = false,
  });

  /// The job read back from its payload.
  factory PerformConversionsJob.fromJson(Map<String, Object?> json) =>
      PerformConversionsJob(
        (json['media_id']! as num).toInt(),
        conversions: (json['conversions'] as List<Object?>?)
            ?.cast<String>()
            .toList(),
        onlyMissing: json['only_missing'] == true,
      );

  /// The job name in the payload.
  static const String name = 'media-library.perform-conversions';

  /// The definition to list in `bootstrap/jobs.dart`.
  static const JobDefinition definition = JobDefinition(
    name,
    PerformConversionsJob.fromJson,
  );

  /// The media's id.
  final int mediaId;

  /// The conversions to generate; all of the media's when null.
  final List<String>? conversions;

  /// Whether only missing conversions are generated.
  final bool onlyMissing;

  @override
  String get jobName => name;

  @override
  int get tries => 3;

  @override
  Map<String, Object?> toJson() => {
    'media_id': mediaId,
    'conversions': conversions,
    'only_missing': onlyMissing,
  };

  @override
  Future<void> handle(JobContext ctx) async {
    // Deleted since it was queued: nothing to convert.
    final media = await Media.query().whereKey(mediaId).first();
    if (media == null) {
      return;
    }
    await MediaLibrary.performConversions(
      media,
      only: conversions,
      onlyMissing: onlyMissing,
      now: true,
    );
  }
}
