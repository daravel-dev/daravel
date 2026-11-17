import 'package:image/image.dart' as img;

import 'conversion.dart';

/// Runs [body], a call into `package:image` (reading a file's header,
/// decoding, encoding), and turns what it throws into this library's
/// exceptions: an [img.ImageException] past a size limit into
/// [ImageTooLargeException], another one into [ImageConversionException],
/// and an [Error] (a defect of the image library for this file) into
/// [ImageLibraryException], so the file fails once instead of being tried
/// again. [OutOfMemoryError] and [StackOverflowError] are about the process,
/// not the file: thrown as they are. Not exported: the conversion's own
/// boundary, tested by its own tests.
///
/// The pixel budget error (checked per frame and over all frames or pages,
/// with our limit) is told by its message, which `package:image` does not
/// type. Our own checks run first, on what the header read reports; the
/// package's own budget still covers what only decoding reaches. Should
/// that message change, such a file becomes an [ImageConversionException]:
/// still refused, only named differently.
T guardImageCall<T>(T Function() body) {
  try {
    return body();
  } on img.ImageException catch (error) {
    throw error.message.contains('exceed the maximum')
        ? ImageTooLargeException('${error.message}; it was not converted.')
        : ImageConversionException(error.message);
  } on OutOfMemoryError {
    rethrow;
  } on StackOverflowError {
    rethrow;
    // ignore: avoid_catching_errors
  } on Error catch (error) {
    // Only here, at the call into the image library: the Error is its
    // defect, met on one file; our own code outside throws as it is.
    throw ImageLibraryException(
      '${error.runtimeType}',
      '$error'.split('\n').first,
    );
  }
}
