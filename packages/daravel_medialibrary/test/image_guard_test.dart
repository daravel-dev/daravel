import 'dart:isolate';

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

  test('each exception names its class in toString, written out (not '
      'runtimeType, which an obfuscated build renames)', () {
    expect(
      const ImageConversionException('m').toString(),
      'ImageConversionException: m',
    );
    expect(
      const ImageTooLargeException('m').toString(),
      'ImageTooLargeException: m',
    );
    expect(
      const ImageLibraryException('RangeError', 'd').toString(),
      'ImageLibraryException: The image library failed (RangeError): d',
    );
  });

  test('running out of memory is thrown as it is', () {
    expect(
      () => guardImageCall<void>(() => throw OutOfMemoryError()),
      throwsA(isA<OutOfMemoryError>()),
    );
  });

  test("a stack overflow is the file's (a conversion runs in an isolate of "
      'its own): an ImageLibraryException, so its job fails once', () {
    expect(
      () => guardImageCall<void>(() => throw StackOverflowError()),
      throwsA(
        isA<ImageLibraryException>().having(
          (e) => e.errorType,
          'errorType',
          'StackOverflowError',
        ),
      ),
    );
  });

  test('a real stack overflow in a conversion isolate reaches the caller as '
      'an ImageLibraryException', () async {
    await expectLater(
      Isolate.run(() => guardImageCall(() => _deep(1 << 30))),
      throwsA(
        isA<ImageLibraryException>().having(
          (e) => e.errorType,
          'errorType',
          'StackOverflowError',
        ),
      ),
    );
  });

  test('the type of an Error is named without runtimeType: a known core '
      'type by its name, any other as Error', () {
    for (final (error, name) in <(Error, String)>[
      (RangeError('x'), 'RangeError'),
      (ArgumentError('x'), 'ArgumentError'),
      (StateError('x'), 'StateError'),
      (UnsupportedError('x'), 'UnsupportedError'),
      (StackOverflowError(), 'StackOverflowError'),
      (_OddError(), 'Error'),
    ]) {
      expect(
        () => guardImageCall<void>(() => throw error),
        throwsA(
          isA<ImageLibraryException>().having(
            (e) => e.errorType,
            'errorType',
            name,
          ),
        ),
        reason: name,
      );
    }
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

int _deep(int n) => n == 0 ? 0 : 1 + _deep(n - 1);

final class _OddError extends Error {}
