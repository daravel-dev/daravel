/// The walk the conversion follows through a JPEG before decoding it, for
/// its checks. Not exported: the conversion's own, tested by its own tests.
library;

import 'dart:typed_data';

/// The next marker from [at]: every byte up to an `FF` is passed over,
/// then the `FF` fill bytes after it, and `FF 00` is no marker (the search
/// goes on), as ITU-T T.81 defines markers (B.1.1.2, B.1.1.3). [at] of the
/// result is the marker byte, [after] the byte after it. Null when the
/// bytes end first or right after the marker.
({int marker, int at, int after})? jpegMarker(Uint8List bytes, int at) {
  final n = bytes.length;
  var i = at;
  if (i >= n) {
    return null;
  }
  int c;
  do {
    do {
      c = bytes[i++];
    } while (c != 0xFF && i < n);
    if (i >= n) {
      return null;
    }
    do {
      c = bytes[i++];
    } while (c == 0xFF && i < n);
  } while (c == 0 && i < n);
  if (i >= n) {
    return null;
  }
  return (marker: c, at: i - 1, after: i);
}

/// The segments of a JPEG after its start of image ([from]): each marker
/// found by [jpegMarker]; RSTn and TEM have no length; EOI ends the walk;
/// any other marker is followed by a 16-bit length that counts itself, and
/// the next marker is searched after the block it covers. [next] is where
/// the following search starts; [length] is -1 without a length. The walk
/// ends after a length below 2 or when the bytes end. Entropy-coded data
/// after a scan is passed over by the next search, byte by byte.
///
/// An SOI after the first is read with a length, and the scan count treats
/// it as a marker it does not follow (counting every scan of the file).
Iterable<({int marker, int at, int next, int length})> jpegSegments(
  Uint8List bytes,
  int from,
) sync* {
  final n = bytes.length;
  var at = from;
  while (true) {
    final found = jpegMarker(bytes, at);
    if (found == null) {
      return;
    }
    final (:marker, at: markerAt, :after) = found;
    final standalone =
        (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 || marker == 0xD9;
    if (standalone) {
      yield (marker: marker, at: markerAt, next: after, length: -1);
      if (marker == 0xD9) {
        return;
      }
      at = after;
      continue;
    }
    if (after + 2 > n) {
      return; // the length is cut off
    }
    final length = (bytes[after] << 8) | bytes[after + 1];
    yield (marker: marker, at: markerAt, next: after + length, length: length);
    if (length < 2) {
      return;
    }
    at = after + length;
  }
}

/// A start of frame marker: `FF Cn`, n from 0 to 15 but 4 (DHT), 8 (JPG)
/// and 12 (DAC).
bool isJpegFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;

/// The scans the conversion counts in [bytes] before decoding them, and the
/// frame it holds them to (see its check for the rules).
(int scans, int width, int height) jpegScanBound(
  Uint8List bytes,
  int width,
  int height,
  int maxPixels,
) {
  final n = bytes.length;
  var frameWidth = width;
  var frameHeight = height;

  void frameAt(int ff) {
    if (ff + 8 >= n) {
      return;
    }
    final h = (bytes[ff + 5] << 8) | bytes[ff + 6];
    final w = (bytes[ff + 7] << 8) | bytes[ff + 8];
    // Both at most 65 535: the products fit.
    if (w >= 1 &&
        h >= 1 &&
        w <= maxPixels ~/ h &&
        w * h > frameWidth * frameHeight) {
      frameWidth = w;
      frameHeight = h;
    }
  }

  // Where every `FF DA` starts to count: after the first scan's header, or
  // from the first byte for any marker the walk does not follow.
  var scans = 0;
  var countFrom = -1;
  final start = jpegMarker(bytes, 0);
  if (start == null || start.marker != 0xD8) {
    countFrom = 0;
  } else {
    walk:
    for (final (:marker, :at, :next, :length) in jpegSegments(
      bytes,
      start.after,
    )) {
      if (length != -1 && length < 2) {
        countFrom = 0;
        break walk;
      }
      switch (marker) {
        case 0xD9:
          break walk; // the end of the image, before any scan
        case >= 0xD0 && <= 0xD7 || 0x01: // RSTn, TEM
        case >= 0xE0 && <= 0xEF || 0xFE: // APPn, COM
        case 0xDB || 0xC4 || 0xDD: // DQT, DHT, DRI
          break;
        case 0xC0 || 0xC1 || 0xC2: // the frame types converted
          frameAt(at - 1);
        case 0xDA:
          scans = 1;
          countFrom = next;
          break walk;
        default:
          countFrom = 0;
          break walk;
      }
    }
  }
  if (countFrom == 0) {
    scans = 0;
  }
  if (countFrom >= 0) {
    for (var i = countFrom; i + 1 < n; i++) {
      if (bytes[i] != 0xFF) {
        continue;
      }
      final marker = bytes[i + 1];
      if (marker == 0xDA) {
        scans++;
      } else if (isJpegFrame(marker)) {
        // A fence: only tightens the budget (in entropy-coded data `FF` is
        // followed by `00`).
        frameAt(i);
      }
    }
  }
  return (scans, frameWidth, frameHeight);
}
