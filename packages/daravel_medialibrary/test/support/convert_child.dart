import 'dart:io';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';

/// Converts the image at the path given to a 100-pixel-wide JPEG with the
/// default limits, in a process of its own so a test can bound its time
/// and memory, and prints one line (`ok BYTES` or `error TYPE`), then
/// `rss PEAK_BYTES`.
void main(List<String> args) {
  try {
    final out = convertImageSync(File(args.single).readAsBytesSync(), {
      'width': [100],
    });
    stdout.writeln('ok ${out.length}');
  } on Object catch (error) {
    stdout.writeln('error ${error.runtimeType}');
  }
  stdout.writeln('rss ${ProcessInfo.maxRss}');
}
