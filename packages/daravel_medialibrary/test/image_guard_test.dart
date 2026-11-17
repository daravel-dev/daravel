import 'package:daravel_medialibrary/daravel_medialibrary.dart';
// The conversion's own boundary with the image library; not exported.
import 'package:daravel_medialibrary/src/image_guard.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// What the image library throws while it reads, decodes or encodes a file
/// reaches the conversion as this library's exceptions. The errors are
/// thrown here on purpose: no file is known to make the library throw one
/// since a 16-bit image goes to the GIF encoder as 8 bits.
void main() {
  test('an Error of the image library is an ImageLibraryException, an '
      'ImageConversionException (its job fails once)', () {
    expect(
      () => guardImageCall<void>(() => throw RangeError('index 35494')),
      throwsA(
        isA<ImageLibraryException>()
            .having((e) => e.errorType, 'errorType', 'RangeError')
            .having(
              (e) => e.message,
              'message',
              'The image library failed (RangeError): '
                  'RangeError: index 35494',
            ),
      ),
    );
    expect(
      () => guardImageCall<void>(() => throw StateError('bad state')),
      throwsA(isA<ImageConversionException>()),
    );
  });

  test('running out of memory or stack is thrown as it is', () {
    expect(
      () => guardImageCall<void>(() => throw OutOfMemoryError()),
      throwsA(isA<OutOfMemoryError>()),
    );
    expect(
      () => guardImageCall<void>(() => throw StackOverflowError()),
      throwsA(isA<StackOverflowError>()),
    );
  });

  test("the library's own exceptions keep their meaning", () {
    expect(
      () => guardImageCall<void>(
        () => throw img.ImageException('Image dimensions exceed the maximum'),
      ),
      throwsA(isA<ImageTooLargeException>()),
    );
    expect(
      () => guardImageCall<void>(
        () => throw img.ImageException('Invalid PNG chunk'),
      ),
      throwsA(
        isA<ImageConversionException>().having(
          (e) => e is ImageTooLargeException,
          'too large',
          isFalse,
        ),
      ),
    );
  });

  test('our own checks between the library calls throw as they are', () {
    // Under a limit of 100 pixels a manipulation may make 25: each of these
    // asks for more, refused by our size check before the library is called.
    final png = img.encodePng(img.Image(width: 2, height: 2));
    final tooLarge = isA<ImageTooLargeException>()
        .having((e) => e is ImageLibraryException, 'library', isFalse)
        .having(
          (e) => e.message,
          'message',
          startsWith('The conversion would make'),
        );
    for (final manipulations in <Map<String, List<Object?>>>[
      {
        'width': [20],
      },
      {
        'crop': [20, 20, 'center'],
      },
      {
        'fit': ['fill', 20, 20],
      },
    ]) {
      expect(
        () => convertImageSync(png, manipulations, maxPixels: 100),
        throwsA(tooLarge),
        reason: '$manipulations',
      );
    }
  });

  test('an Exception that is not the library\'s is not touched', () {
    expect(
      () => guardImageCall<void>(() => throw const FormatException('ours')),
      throwsA(isA<FormatException>()),
    );
  });
}
