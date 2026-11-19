import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:daravel_medialibrary/src/jpeg_walk.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

/// A marker as the last byte of a JPEG: the decoder reads it, the walk's
/// marker search ends one byte short of it. No scan the conversion pays for
/// goes uncounted: cut at the first scan, the file is refused before it is
/// decoded; a later scan marker last is counted by the byte search.
void main() {
  final full = img.encodeJpg(
    img.Image(width: 64, height: 48)..clear(img.ColorRgb8(10, 20, 30)),
  );
  var sos = -1;
  for (var i = 0; i + 1 < full.length; i++) {
    if (full[i] == 0xFF && full[i + 1] == 0xDA) {
      sos = i;
      break;
    }
  }

  Matcher refused() => throwsA(
    isA<ImageConversionException>().having(
      (e) => e.message,
      'message',
      contains('is not a JPEG'),
    ),
  );

  test('the first scan marker as the last byte: refused before decoding', () {
    final bytes = Uint8List.sublistView(full, 0, sos + 2);
    expect(bytes.last, 0xDA);
    expect(jpegScanBound(bytes, 64, 48, 1 << 30).$1, 0);
    expect(
      () => convertImageSync(bytes, {
        'width': [32],
      }),
      refused(),
    );
  });

  test('cut on the FF of the first scan marker: refused before decoding', () {
    final bytes = Uint8List.sublistView(full, 0, sos + 1);
    expect(
      () => convertImageSync(bytes, {
        'width': [32],
      }),
      refused(),
    );
  });

  test('a later scan marker as the last byte is counted', () {
    final bytes = Uint8List.fromList([
      ...full.sublist(0, full.length - 2),
      0xFF,
      0xDA,
    ]);
    expect(jpegScanBound(bytes, 64, 48, 1 << 30).$1, 2);
  });
}
