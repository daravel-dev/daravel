// Generates the Daravel brand assets (BLUEPRINT_V2 §8 / docs/brand).
//
//   dart run tool/brand/generate.dart            # SVG + PNG + ICO + starter data
//   dart run tool/brand/generate.dart --svg-only # SVG only (no Chrome needed)
//
// The source of truth is the illustration in docs/brand/source: the navy
// tile is found in it, cropped and given the icon's rounded corners; the
// transparent mark is keyed out of the tile's navy background. The SVGs
// wrap those rasters (and the stroke-built wordmark), the icon and mark
// PNGs are resized here, and the lockups and the social preview are
// rendered with headless Chrome (CHROME env var or the default install
// path). The favicon.ico packs PNG-encoded frames.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:image/image.dart' as img;

const String navy = '#11133a';
const String navyDeep = '#0b0d2a';

/// The illustration every asset is made from.
const String sourcePath = 'docs/brand/source/daravel-icon-source.jpg';

/// Corner radius of the icon tile, as a fraction of its side (112 / 512).
const double cornerRatio = 112 / 512;

String _n(num v) => v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');

/// The navy tile of [source]: the square of dark pixels around the
/// centre, inset a little so no light margin or soft edge survives. Its
/// corners are cut again by [roundCorners], with a radius larger than the
/// illustration's own.
img.Image cropTile(img.Image source) {
  bool dark(int x, int y) {
    final p = source.getPixel(x, y);
    return p.r + p.g + p.b < 200;
  }

  final cx = source.width ~/ 2, cy = source.height ~/ 2;
  var left = cx, right = cx, top = cy, bottom = cy;
  for (var x = 0; x < source.width; x++) {
    if (dark(x, cy)) {
      left = math.min(left, x);
      right = math.max(right, x);
    }
  }
  for (var y = 0; y < source.height; y++) {
    if (dark(cx, y)) {
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
  }
  final side = math.min(right - left, bottom - top) + 1;
  final inset = (side * 0.004).ceil();
  final size = side - 2 * inset;
  return img
      .copyCrop(
        source,
        x: left + inset,
        y: top + inset,
        width: size,
        height: size,
      )
      .convert(numChannels: 4);
}

/// [image] resized to [width] (and [height]) by averaging, which keeps
/// detail at every downscale.
img.Image resized(img.Image image, int width, [int? height]) => img.copyResize(
  image,
  width: width,
  height: height ?? (image.height * width / image.width).round(),
  interpolation: img.Interpolation.average,
);

/// [tile] with transparent rounded corners (radius [cornerRatio] of the
/// side), anti-aliased by 4 × 4 supersampling.
img.Image roundCorners(img.Image tile) {
  final out = tile.clone();
  final w = out.width, h = out.height;
  final r = w * cornerRatio;
  double coverage(int x, int y) {
    var inside = 0;
    for (var sy = 0; sy < 4; sy++) {
      for (var sx = 0; sx < 4; sx++) {
        final px = x + (sx + 0.5) / 4, py = y + (sy + 0.5) / 4;
        final dx = px < r ? r - px : (px > w - r ? px - (w - r) : 0.0);
        final dy = py < r ? r - py : (py > h - r ? py - (h - r) : 0.0);
        if (dx * dx + dy * dy <= r * r) {
          inside++;
        }
      }
    }
    return inside / 16;
  }

  final reach = r.ceil() + 1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final nearX = x < reach || x >= w - reach;
      final nearY = y < reach || y >= h - reach;
      if (!nearX || !nearY) {
        continue;
      }
      final c = coverage(x, y);
      if (c < 1) {
        final p = out.getPixel(x, y);
        p.a = (p.a * c).round();
      }
    }
  }
  return out;
}

/// The icon at [size] pixels.
img.Image iconImage(img.Image tile, int size) =>
    roundCorners(resized(tile, size));

/// The mark without its tile: every pixel's alpha is how far its colour
/// rises above the navy background behind it, and its colour is that
/// background taken back out. Dark outlines and drop shadows go
/// transparent. The background is a Coons patch through strips along the
/// four edges of the tile, so the lighter glow at the top is modelled;
/// the corners, light in the illustration, are skipped. Cropped to the
/// mark with a small margin.
img.Image keyMark(img.Image tile) {
  final w = tile.width, h = tile.height;
  final from = (w * 0.02).round(), to = (w * 0.06).round();
  final corner = (w * 0.21).round();
  List<double> average(Iterable<img.Pixel> pixels) {
    final sum = [0.0, 0.0, 0.0];
    var n = 0;
    for (final p in pixels) {
      sum[0] += p.r;
      sum[1] += p.g;
      sum[2] += p.b;
      n++;
    }
    return [for (final s in sum) s / n];
  }

  Iterable<img.Pixel> rowStrip(int y, int x0, int x1) sync* {
    for (var x = x0; x < x1; x++) {
      yield tile.getPixel(x, y);
    }
  }

  Iterable<img.Pixel> columnStrip(int x, int y0, int y1) sync* {
    for (var y = y0; y < y1; y++) {
      yield tile.getPixel(x, y);
    }
  }

  // Edge profiles, measured away from the corners and held flat into them.
  final left = [
    for (var y = 0; y < h; y++)
      average(rowStrip(y.clamp(corner, h - 1 - corner), from, to)),
  ];
  final right = [
    for (var y = 0; y < h; y++)
      average(rowStrip(y.clamp(corner, h - 1 - corner), w - to, w - from)),
  ];
  final top = [
    for (var x = 0; x < w; x++)
      average(columnStrip(x.clamp(corner, w - 1 - corner), from, to)),
  ];
  final bottom = [
    for (var x = 0; x < w; x++)
      average(columnStrip(x.clamp(corner, w - 1 - corner), h - to, h - from)),
  ];
  List<double> mean(List<double> a, List<double> b) => [
    for (var c = 0; c < 3; c++) (a[c] + b[c]) / 2,
  ];
  final p00 = mean(left.first, top.first);
  final p10 = mean(right.first, top.last);
  final p01 = mean(left.last, bottom.first);
  final p11 = mean(right.last, bottom.last);

  const low = 28.0, high = 80.0;
  final out = img.Image(width: w, height: h, numChannels: 4);
  var minX = w, minY = h, maxX = 0, maxY = 0;
  for (var y = 0; y < h; y++) {
    final v = y / (h - 1);
    for (var x = 0; x < w; x++) {
      final dx = x < corner
          ? corner - x
          : (x >= w - corner ? x - (w - 1 - corner) : 0);
      final dy = y < corner
          ? corner - y
          : (y >= h - corner ? y - (h - 1 - corner) : 0);
      if (dx * dx + dy * dy > corner * corner) {
        continue;
      }
      final u = x / (w - 1);
      final bg = [
        for (var c = 0; c < 3; c++)
          (1 - u) * left[y][c] +
              u * right[y][c] +
              (1 - v) * top[x][c] +
              v * bottom[x][c] -
              ((1 - u) * (1 - v) * p00[c] +
                  u * (1 - v) * p10[c] +
                  (1 - u) * v * p01[c] +
                  u * v * p11[c]),
      ];
      final p = tile.getPixel(x, y);
      final rgb = [p.r.toDouble(), p.g.toDouble(), p.b.toDouble()];
      final rise = math.max(
        rgb[0] - bg[0],
        math.max(rgb[1] - bg[1], rgb[2] - bg[2]),
      );
      final a = ((rise - low) / (high - low)).clamp(0.0, 1.0);
      if (a <= 0) {
        continue;
      }
      final alpha = a * a * (3 - 2 * a);
      final clean = [
        for (var c = 0; c < 3; c++)
          (bg[c] + (rgb[c] - bg[c]) / alpha).clamp(0.0, 255.0).round(),
      ];
      out.setPixelRgba(
        x,
        y,
        clean[0],
        clean[1],
        clean[2],
        (alpha * 255).round(),
      );
      if (alpha > 0.05) {
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
      }
    }
  }
  final margin = (w * 0.01).round();
  final x0 = math.max(0, minX - margin), y0 = math.max(0, minY - margin);
  return img.copyCrop(
    out,
    x: x0,
    y: y0,
    width: math.min(w, maxX + margin + 1) - x0,
    height: math.min(h, maxY + margin + 1) - y0,
  );
}

/// [mark] in one colour ([hex], `#rrggbb`): its alpha blurred a little and
/// thresholded, so the silhouette has clean edges, thin ornaments stay
/// solid and the specks where the ribbons' darkest shading keyed out are
/// filled.
img.Image monoMark(img.Image mark, String hex) {
  final r = int.parse(hex.substring(1, 3), radix: 16);
  final g = int.parse(hex.substring(3, 5), radix: 16);
  final b = int.parse(hex.substring(5, 7), radix: 16);
  final coverage = img.Image(width: mark.width, height: mark.height);
  for (final p in mark) {
    coverage.setPixelRgb(p.x, p.y, p.a, p.a, p.a);
  }
  final blurred = img.gaussianBlur(
    coverage,
    radius: math.max(1, (mark.width * 0.006).round()),
  );
  final out = img.Image(width: mark.width, height: mark.height, numChannels: 4);
  for (final p in blurred) {
    final t = ((p.r / 255 - 0.15) / 0.25).clamp(0.0, 1.0);
    final a = t * t * (3 - 2 * t);
    out.setPixelRgba(p.x, p.y, r, g, b, (a * 255).round());
  }
  return out;
}

String _dataUri(String type, List<int> bytes) =>
    'data:$type;base64,${base64.encode(bytes)}';

/// The icon tile as an SVG `<image>` at ([x], [y]), [size] wide, clipped to
/// the rounded tile. [jpeg] is the tile without its corners cut.
String tileImage(
  Uint8List jpeg, {
  num x = 0,
  num y = 0,
  num size = 512,
  String id = 't',
}) =>
    '<clipPath id="$id"><rect x="${_n(x)}" y="${_n(y)}" width="${_n(size)}" height="${_n(size)}" '
    'rx="${_n(size * cornerRatio)}"/></clipPath>'
    '<image href="${_dataUri('image/jpeg', jpeg)}" x="${_n(x)}" y="${_n(y)}" '
    'width="${_n(size)}" height="${_n(size)}" clip-path="url(#$id)"/>';

/// App icon: the navy tile with the mark.
String iconSvg(Uint8List jpeg, {int size = 512}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="$size" height="$size" '
    'role="img" aria-label="Daravel">${tileImage(jpeg)}</svg>';

/// Mark without tile (transparent), from a PNG of [width] × [height].
String markSvg(Uint8List png, int width, int height) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" width="$width" '
    'height="$height" role="img" aria-label="Daravel">'
    '<image href="${_dataUri('image/png', png)}" width="$width" height="$height"/></svg>';

/// Stroke-built geometric wordmark (no font dependency).
String wordmarkPaths(String color, {num x = 0, num y = 0, num scale = 1}) {
  const letters = <String, ({String d, num w})>{
    'D': (d: 'M8 8 H44 Q76 8 76 40 V68 Q76 100 44 100 H8 Z', w: 84),
    'A': (d: 'M4 100 L42 8 L80 100 M20 66 H64', w: 84),
    'R': (d: 'M8 100 V8 H48 Q76 8 76 34 Q76 60 48 60 H8 M44 60 L78 100', w: 84),
    'V': (d: 'M4 8 L42 100 L80 8', w: 84),
    'E': (d: 'M70 8 H8 V100 H70 M8 54 H60', w: 76),
    'L': (d: 'M8 4 V100 H68', w: 72),
  };
  final buffer = StringBuffer(
    '<g transform="translate(${_n(x)} ${_n(y)}) scale($scale)" fill="none" stroke="$color" '
    'stroke-width="15" stroke-linejoin="miter" stroke-linecap="square">',
  );
  var cursor = 0.0;
  for (final ch in 'DARAVEL'.split('')) {
    final letter = letters[ch]!;
    buffer.write(
      '<path transform="translate(${_n(cursor)} 0)" d="${letter.d}"/>',
    );
    cursor += letter.w + 18;
  }
  buffer.write('</g>');
  return buffer.toString();
}

/// Width of the wordmark at scale 1.
const num wordmarkWidth = 84 * 5 + 76 + 72 + 18 * 6;

/// Icon + wordmark lockup. [onDark] picks the text colour.
String horizontalSvg(Uint8List jpeg, {required bool onDark, int height = 160}) {
  const h = 512.0;
  const textScale = 1.9;
  final width = 512 + 70 + wordmarkWidth * textScale;
  final text = onDark ? '#f8fafc' : navy;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(width)} ${_n(h)}" '
      'width="${(height * width / h).round()}" height="$height" role="img" aria-label="Daravel">'
      '${tileImage(jpeg)}'
      '${wordmarkPaths(text, x: 582, y: h / 2 - 54 * textScale, scale: textScale)}</svg>';
}

/// GitHub/OpenGraph social preview (1280 × 640).
String socialSvg(Uint8List jpeg) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640">'
    '<rect width="1280" height="640" fill="$navyDeep"/>'
    '${tileImage(jpeg, x: 110, y: 170, size: 300)}'
    '${wordmarkPaths('#f8fafc', x: 470, y: 214, scale: 1.0)}'
    '<g fill="#94a3b8" font-family="Segoe UI, Inter, Helvetica, Arial, sans-serif" font-size="32">'
    '<text x="474" y="392">The Laravel experience,</text>'
    '<text x="474" y="436">compiled to a single native binary.</text></g></svg>';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final out = Directory('$root/docs/brand');
  final svgDir = Directory('${out.path}/svg')..createSync(recursive: true);
  final pngDir = Directory('${out.path}/png')..createSync(recursive: true);

  final source = img.decodeJpg(File('$root/$sourcePath').readAsBytesSync());
  if (source == null) {
    throw StateError('$sourcePath is not a JPEG.');
  }
  final tile = cropTile(source);
  final mark = keyMark(tile);
  int markHeight(int width) => (width * mark.height / mark.width).round();
  Uint8List jpeg(int size) =>
      img.encodeJpg(resized(tile.convert(numChannels: 3), size), quality: 90);
  Uint8List png(img.Image image) => img.encodePng(image, level: 9);

  final tileJpeg = jpeg(512);
  final mark512 = resized(mark, 512);
  final svgs = <String, String>{
    'daravel-icon': iconSvg(tileJpeg),
    'daravel-icon-small': iconSvg(jpeg(128), size: 48),
    'daravel-mark': markSvg(png(mark512), 512, mark512.height),
    'daravel-mark-mono-white': markSvg(
      png(monoMark(mark512, '#ffffff')),
      512,
      mark512.height,
    ),
    'daravel-mark-mono-navy': markSvg(
      png(monoMark(mark512, navy)),
      512,
      mark512.height,
    ),
    'daravel-logo-horizontal-on-dark': horizontalSvg(tileJpeg, onDark: true),
    'daravel-logo-horizontal-on-light': horizontalSvg(tileJpeg, onDark: false),
    'daravel-social': socialSvg(tileJpeg),
  };
  for (final entry in svgs.entries) {
    File('${svgDir.path}/${entry.key}.svg')
        .writeAsStringSync('${entry.value}\n');
  }
  stdout.writeln('Wrote ${svgs.length} SVGs to docs/brand/svg');
  if (args.contains('--svg-only')) {
    return;
  }

  final rasters = <String, img.Image>{
    for (final s in [16, 32, 48, 64, 128, 180, 192, 256, 512, 1024])
      'daravel-icon-$s': iconImage(tile, s),
    for (final s in [128, 256, 512, 1024]) 'daravel-mark-$s': resized(mark, s),
    for (final s in [256, 512]) ...{
      'daravel-mark-mono-white-$s': monoMark(resized(mark, s), '#ffffff'),
      'daravel-mark-mono-navy-$s': monoMark(resized(mark, s), navy),
    },
  };
  for (final entry in rasters.entries) {
    File('${pngDir.path}/${entry.key}.png').writeAsBytesSync(png(entry.value));
  }

  final renders = <({String name, String svg, int w, int h})>[
    for (final h in [64, 128, 256])
      (
        name: 'daravel-logo-horizontal-on-dark-$h',
        svg: horizontalSvg(tileJpeg, onDark: true, height: h),
        w: _hw(h),
        h: h,
      ),
    for (final h in [64, 128, 256])
      (
        name: 'daravel-logo-horizontal-on-light-$h',
        svg: horizontalSvg(tileJpeg, onDark: false, height: h),
        w: _hw(h),
        h: h,
      ),
    (
      name: 'daravel-social-1280x640',
      svg: socialSvg(tileJpeg),
      w: 1280,
      h: 640,
    ),
  ];
  final chrome = _chrome();
  final tmp = Directory.systemTemp.createTempSync('daravel_brand_');
  for (final r in renders) {
    final html = File('${tmp.path}/${r.name}.html')
      ..writeAsStringSync(
        '<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}'
        'svg{display:block}</style></head><body>${r.svg}</body></html>',
      );
    final target = '${pngDir.path}/${r.name}.png';
    final result = await Process.run(chrome, [
      '--headless=new',
      '--disable-gpu',
      '--hide-scrollbars',
      '--default-background-color=00000000',
      '--window-size=${r.w},${r.h}',
      '--screenshot=${File(target).absolute.path}',
      Uri.file(html.path).toString(),
    ]);
    if (!File(target).existsSync()) {
      stderr.writeln('Render failed for ${r.name}: ${result.stderr}');
      exitCode = 1;
      return;
    }
  }
  tmp.deleteSync(recursive: true);
  stdout.writeln(
    'Wrote ${rasters.length + renders.length} PNGs to docs/brand/png '
    '(mark ${mark.width} x ${mark.height} at source scale, '
    '1024 px wide: ${markHeight(1024)} px high)',
  );

  _writeIco(
    '${out.path}/favicon.ico',
    [
      for (final s in [16, 32, 48])
        File('${pngDir.path}/daravel-icon-$s.png').readAsBytesSync(),
    ],
    [16, 32, 48],
  );
  stdout.writeln('Wrote docs/brand/favicon.ico');

  final logo = base64.encode(
    File('${pngDir.path}/daravel-icon-128.png').readAsBytesSync(),
  );
  final favicon = base64.encode(
    File('${pngDir.path}/daravel-icon-32.png').readAsBytesSync(),
  );
  File('$root/packages/daravel/lib/src/support/brand.dart').writeAsStringSync(
    '// Generated by tool/brand/generate.dart from the Daravel mark. Do not edit by hand.\n\n'
    '/// The Daravel icon (128 px PNG) as a data URI, for welcome pages: embedded\n'
    '/// so an AOT binary serves it without static files. Unused constants are\n'
    '/// tree-shaken from builds.\n'
    "const String daravelLogoDataUri =\n    'data:image/png;base64,$logo';\n\n"
    '/// The Daravel favicon (32 px PNG) as a data URI.\n'
    "const String daravelFaviconDataUri =\n    'data:image/png;base64,$favicon';\n",
  );
  stdout.writeln('Updated packages/daravel/lib/src/support/brand.dart');
}

int _hw(int h) => (h * (512 + 70 + wordmarkWidth * 1.9) / 512).round();

String _chrome() {
  final fromEnv = Platform.environment['CHROME'];
  final candidates = [
    ?fromEnv,
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  throw StateError('Chrome/Chromium not found; set CHROME=/path/to/chrome.');
}

/// ICO container with PNG-encoded frames (supported since Windows Vista).
void _writeIco(String path, List<List<int>> pngs, List<int> sizes) {
  final header = BytesBuilder()
    ..add([0, 0, 1, 0, pngs.length & 0xff, pngs.length >> 8]);
  var offset = 6 + 16 * pngs.length;
  for (var i = 0; i < pngs.length; i++) {
    final size = sizes[i] >= 256 ? 0 : sizes[i];
    final len = pngs[i].length;
    header.add([
      size,
      size,
      0,
      0,
      1,
      0,
      32,
      0,
      len & 0xff,
      (len >> 8) & 0xff,
      (len >> 16) & 0xff,
      (len >> 24) & 0xff,
      offset & 0xff,
      (offset >> 8) & 0xff,
      (offset >> 16) & 0xff,
      (offset >> 24) & 0xff,
    ]);
    offset += len;
  }
  for (final png in pngs) {
    header.add(png);
  }
  File(path).writeAsBytesSync(header.toBytes());
}
