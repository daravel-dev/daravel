/// The pixel size of an image from its first bytes, as PHP's
/// `getimagesize` reads it for `dimensions`, for PNG, GIF, JPEG, WebP and
/// BMP. The bytes come from an upload, so they are untrusted: every read is
/// checked against their length, and a header that is cut or malformed
/// gives null, never an exception. A declared size of zero is returned as
/// PHP returns it (`[0, 10]`); the rule decides what it means.
library;

import 'dart:async';
import 'dart:typed_data';

import '../http/uploaded_file.dart';

/// The most bytes read from an upload to find its size. A JPEG's size comes
/// after its metadata segments (EXIF, ICC, XMP); one whose metadata is
/// longer than this has no size here and fails `dimensions`.
const int maxImageHeaderBytes = 256 * 1024;

/// The first [maxImageHeaderBytes] of [file] (fewer when it is shorter).
Future<Uint8List> imageHeaderOf(UploadedFile file) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    final room = maxImageHeaderBytes - out.length;
    out.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
    if (out.length >= maxImageHeaderBytes) {
      break;
    }
  }
  return out.takeBytes();
}

/// The width and height in [head], or null when it is not a whole PNG, GIF,
/// JPEG, WebP or BMP header.
({int width, int height})? imageSize(Uint8List head) =>
    _png(head) ?? _gif(head) ?? _jpeg(head) ?? _webp(head) ?? _bmp(head);

bool _starts(Uint8List b, List<int> magic, [int at = 0]) {
  if (b.length < at + magic.length) {
    return false;
  }
  for (var i = 0; i < magic.length; i++) {
    if (b[at + i] != magic[i]) {
      return false;
    }
  }
  return true;
}

int _u16be(Uint8List b, int at) => b[at] << 8 | b[at + 1];
int _u16le(Uint8List b, int at) => b[at] | b[at + 1] << 8;
int _u32be(Uint8List b, int at) =>
    b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
int _u32le(Uint8List b, int at) =>
    b[at] | b[at + 1] << 8 | b[at + 2] << 16 | b[at + 3] << 24;

// PNG: the signature, then IHDR with width and height (big-endian).
({int width, int height})? _png(Uint8List b) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (!_starts(b, signature) ||
      b.length < 24 ||
      !_starts(b, 'IHDR'.codeUnits, 12)) {
    return null;
  }
  return (width: _u32be(b, 16), height: _u32be(b, 20));
}

// GIF: GIF87a/GIF89a, then the logical screen size (little-endian).
({int width, int height})? _gif(Uint8List b) {
  if (!(_starts(b, 'GIF87a'.codeUnits) || _starts(b, 'GIF89a'.codeUnits)) ||
      b.length < 10) {
    return null;
  }
  return (width: _u16le(b, 6), height: _u16le(b, 8));
}

// JPEG: segments after SOI until a start-of-frame marker, whose header has
// the height then the width; a scan before any frame has no size.
({int width, int height})? _jpeg(Uint8List b) {
  if (!_starts(b, [0xFF, 0xD8])) {
    return null;
  }
  var at = 2;
  while (at < b.length) {
    if (b[at] != 0xFF) {
      return null;
    }
    // Fill bytes (0xFF) before a marker.
    while (at < b.length && b[at] == 0xFF) {
      at++;
    }
    if (at >= b.length) {
      return null;
    }
    final marker = b[at];
    at++;
    // Standalone markers: no length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA || at + 2 > b.length) {
      return null; // End of image or a scan before any frame.
    }
    final length = _u16be(b, at);
    if (length < 2) {
      return null;
    }
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (length < 7 || at + 7 > b.length) {
        return null;
      }
      return (width: _u16be(b, at + 5), height: _u16be(b, at + 3));
    }
    at += length;
  }
  return null;
}

// WebP: RIFF....WEBP, then a VP8 (lossy), VP8L (lossless) or VP8X
// (extended) chunk with the size in its own layout.
({int width, int height})? _webp(Uint8List b) {
  if (!_starts(b, 'RIFF'.codeUnits) ||
      !_starts(b, 'WEBP'.codeUnits, 8) ||
      b.length < 30) {
    return null;
  }
  if (_starts(b, 'VP8 '.codeUnits, 12)) {
    if (!_starts(b, [0x9D, 0x01, 0x2A], 23)) {
      return null;
    }
    return (width: _u16le(b, 26) & 0x3FFF, height: _u16le(b, 28) & 0x3FFF);
  }
  if (_starts(b, 'VP8L'.codeUnits, 12)) {
    if (b[20] != 0x2F) {
      return null;
    }
    final b1 = b[21], b2 = b[22], b3 = b[23], b4 = b[24];
    return (
      width: 1 + ((b2 & 0x3F) << 8 | b1),
      height: 1 + ((b4 & 0x0F) << 10 | b3 << 2 | (b2 & 0xC0) >> 6),
    );
  }
  if (_starts(b, 'VP8X'.codeUnits, 12)) {
    int u24(int at) => b[at] | b[at + 1] << 8 | b[at + 2] << 16;
    return (width: 1 + u24(24), height: 1 + u24(27));
  }
  return null;
}

// BMP: BM, then the DIB header: 16-bit sizes in the OS/2 core header (12
// bytes), 32-bit ones otherwise, the height negative for top-down rows.
({int width, int height})? _bmp(Uint8List b) {
  if (!_starts(b, 'BM'.codeUnits) || b.length < 26) {
    return null;
  }
  final dib = _u32le(b, 14);
  if (dib == 12) {
    return (width: _u16le(b, 18), height: _u16le(b, 20));
  }
  final width = _u32le(b, 18).toSigned(32);
  final height = _u32le(b, 22).toSigned(32);
  return (width: width, height: height.abs());
}
