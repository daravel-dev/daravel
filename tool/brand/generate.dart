// Generates the Daravel brand assets (BLUEPRINT_V2 §8 / docs/brand).
//
//   dart run tool/brand/generate.dart            # SVG + PNG + ICO + starter data
//   dart run tool/brand/generate.dart --svg-only # skip rasterising
//
// The mark is defined here as geometry so it can be reproduced and edited
// in code review. PNGs are rendered with headless Chrome (CHROME env var or
// the default install path); the favicon.ico packs PNG-encoded frames.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

const String navy = '#11133a';
const String navyDeep = '#0b0d2a';
const String gap = '#0b0d2a';

/// A filled part of the mark.
/// A filled part of the mark, or a [cut] line carved out of the parts
/// drawn before it.
final class Part {
  const Part(this.d, this.fill, {this.simple = true}) : cut = false;

  const Part.cut(this.d, {this.simple = false}) : fill = 'none', cut = true;

  final String d;
  final String fill;
  final bool cut;

  /// Kept in the simplified (≤ 48 px) variant.
  final bool simple;
}

String _n(num v) => v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');

String _poly(List<List<num>> points) =>
    'M${points.map((p) => '${_n(p[0])} ${_n(p[1])}').join(' L')} Z';

String _line(List<List<num>> points) =>
    'M${points.map((p) => '${_n(p[0])} ${_n(p[1])}').join(' L')}';

/// A crescent blade from [base] to [tip]: [halfWidth] at the base, curving
/// to the left of the base→tip direction by [bend], [thickness] at the
/// middle.
String _blade(
  List<num> base,
  List<num> tip, {
  num bend = 36,
  num thickness = 24,
  num halfWidth = 14,
}) {
  final bx = base[0].toDouble(), by = base[1].toDouble();
  final tx = tip[0].toDouble(), ty = tip[1].toDouble();
  final dx = tx - bx, dy = ty - by;
  final len = math.sqrt(dx * dx + dy * dy);
  final nx = -dy / len, ny = dx / len;
  final mx = (bx + tx) / 2, my = (by + ty) / 2;
  final b1 = [bx + nx * halfWidth, by + ny * halfWidth];
  final b2 = [bx - nx * halfWidth, by - ny * halfWidth];
  final outer = [mx + nx * (bend + thickness), my + ny * (bend + thickness)];
  final inner = [mx + nx * (bend - thickness), my + ny * (bend - thickness)];
  return 'M${_n(b1[0])} ${_n(b1[1])} Q${_n(outer[0])} ${_n(outer[1])} ${_n(tx)} ${_n(ty)} '
      'Q${_n(inner[0])} ${_n(inner[1])} ${_n(b2[0])} ${_n(b2[1])} Z';
}

/// The dragon, drawn back to front on a 512 × 512 canvas: wing, tail fin,
/// blue belly, red serpentine body with scale cuts, mane, horns, head.
List<Part> dragonParts() => [
  // Wing: broad crescent feathers fanning from the shoulder to the upper
  // left (outer row), with a shorter, lighter inner row.
  Part(
    _blade([246, 296], [78, 96], bend: 46, thickness: 30, halfWidth: 20),
    'url(#wingA)',
  ),
  Part(
    _blade([240, 312], [52, 176], bend: 38, thickness: 26, halfWidth: 18),
    'url(#wingB)',
  ),
  Part(
    _blade([240, 326], [60, 252], bend: 30, thickness: 22, halfWidth: 16),
    'url(#wingA)',
  ),
  Part(
    _blade([248, 340], [104, 310], bend: 22, thickness: 18, halfWidth: 14),
    'url(#wingB)',
    simple: false,
  ),
  Part(
    _blade([256, 306], [140, 186], bend: 24, thickness: 16, halfWidth: 12),
    'url(#wingC)',
    simple: false,
  ),
  Part(
    _blade([258, 320], [134, 246], bend: 18, thickness: 14, halfWidth: 11),
    'url(#wingC)',
    simple: false,
  ),
  Part(
    _blade([262, 334], [156, 296], bend: 12, thickness: 12, halfWidth: 10),
    'url(#wingC)',
    simple: false,
  ),
  // Tail fin fanning to the lower left.
  Part(
    _poly([
      [286, 350],
      [96, 376],
      [186, 392],
      [118, 424],
      [204, 418],
      [146, 458],
      [222, 440],
      [206, 470],
      [270, 446],
      [304, 412],
    ]),
    'url(#fire)',
  ),
  Part.cut(
    _line([
      [280, 360],
      [190, 390],
    ]),
  ),
  Part.cut(
    _line([
      [292, 396],
      [208, 418],
    ]),
  ),
  // Purple depth between belly and body.
  Part(
    'M262 168 C276 230, 318 262, 338 320 C350 360, 352 400, 356 440 '
        'L330 420 C324 380, 316 350, 298 320 C276 284, 258 240, 262 168 Z',
    'url(#violet)',
    simple: false,
  ),
  // Blue belly sweeping from the wing root to the tail tip.
  Part(
    'M204 176 C212 244, 262 282, 296 318 C326 350, 338 394, 352 440 '
        'L306 426 C296 396, 286 376, 266 358 C232 328, 200 290, 204 176 Z',
    'url(#ice)',
  ),
  // Red serpentine body (neck to tail).
  Part(
    'M262 158 C300 150, 336 168, 352 200 C372 236, 404 262, 408 326 '
        'C412 382, 394 414, 360 440 C366 408, 356 380, 348 352 '
        'C338 314, 300 284, 286 246 C276 218, 274 190, 262 158 Z',
    'url(#fire)',
  ),
  // Light facet along the outer edge of the body.
  Part(
    'M352 200 C372 236, 404 262, 408 326 C410 360, 404 386, 392 404 '
        'C392 370, 388 330, 376 296 C366 266, 356 236, 352 200 Z',
    'url(#fireLight)',
    simple: false,
  ),
  // Scale cuts (chevrons across the body).
  Part.cut(
    _line([
      [282, 232],
      [326, 244],
      [368, 222],
    ]),
  ),
  Part.cut(
    _line([
      [312, 284],
      [356, 298],
      [400, 280],
    ]),
  ),
  Part.cut(
    _line([
      [338, 336],
      [376, 348],
      [408, 334],
    ]),
  ),
  Part.cut(
    _line([
      [346, 384],
      [378, 394],
      [402, 382],
    ]),
  ),
  // Mane spikes behind the neck.
  Part(
    _poly([
      [270, 146],
      [236, 122],
      [258, 166],
      [208, 168],
      [256, 194],
      [222, 238],
      [278, 212],
      [290, 168],
    ]),
    'url(#fire)',
  ),
  // Horns sweeping back from the crown (back horn first).
  Part(
    _poly([
      [338, 100],
      [300, 26],
      [330, 70],
      [368, 102],
    ]),
    'url(#ice)',
  ),
  Part(
    _poly([
      [296, 114],
      [226, 36],
      [282, 76],
      [334, 98],
    ]),
    'url(#iceLight)',
  ),
  // Head facets: skull, brow, nose bridge, cheek, upper lip, lower jaw.
  Part(
    _poly([
      [258, 112],
      [330, 96],
      [318, 150],
      [298, 160],
    ]),
    'url(#iceDeep)',
  ),
  Part(
    _poly([
      [330, 96],
      [374, 104],
      [370, 140],
      [318, 150],
    ]),
    'url(#ice)',
  ),
  Part(
    _poly([
      [374, 104],
      [422, 126],
      [460, 150],
      [404, 152],
      [370, 140],
    ]),
    'url(#iceLight)',
  ),
  Part(
    _poly([
      [298, 160],
      [318, 150],
      [370, 140],
      [404, 152],
      [382, 172],
      [332, 196],
    ]),
    'url(#iceDeep)',
  ),
  Part(
    _poly([
      [404, 152],
      [460, 150],
      [458, 166],
      [382, 172],
    ]),
    'url(#ice)',
  ),
  Part(
    _poly([
      [332, 196],
      [382, 172],
      [442, 178],
      [426, 208],
      [404, 196],
      [370, 210],
    ]),
    'url(#ice)',
  ),
  // Mouth line and brow crest.
  Part.cut(
    _line([
      [458, 168],
      [384, 172],
    ]),
  ),
  Part(
    _poly([
      [420, 124],
      [436, 100],
      [440, 134],
    ]),
    'url(#iceLight)',
    simple: false,
  ),
  // Eye.
  Part(
    _poly([
      [352, 118],
      [392, 126],
      [360, 134],
    ]),
    '#e0f7ff',
  ),
];

String defs() =>
    '''
<defs>
  <linearGradient id="tile" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#161a4a"/><stop offset="1" stop-color="$navyDeep"/>
  </linearGradient>
  <linearGradient id="wingA" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#7dd3fc"/><stop offset="1" stop-color="#2563eb"/>
  </linearGradient>
  <linearGradient id="wingB" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#67e8f9"/><stop offset="1" stop-color="#1d4ed8"/>
  </linearGradient>
  <linearGradient id="wingC" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#a5f3fc"/><stop offset="1" stop-color="#0ea5e9"/>
  </linearGradient>
  <linearGradient id="ice" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#38bdf8"/><stop offset="1" stop-color="#1d4ed8"/>
  </linearGradient>
  <linearGradient id="iceLight" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#a5f3fc"/><stop offset="1" stop-color="#38bdf8"/>
  </linearGradient>
  <linearGradient id="iceDeep" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#2563eb"/><stop offset="1" stop-color="#1e3a8a"/>
  </linearGradient>
  <linearGradient id="violet" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#6d28d9"/><stop offset="1" stop-color="#4c1d95"/>
  </linearGradient>
  <linearGradient id="fire" x1="0" y1="0" x2="0.35" y2="1">
    <stop offset="0" stop-color="#fb923c"/><stop offset="0.5" stop-color="#ef4444"/><stop offset="1" stop-color="#e11d48"/>
  </linearGradient>
  <linearGradient id="fireLight" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#fdba74"/><stop offset="1" stop-color="#fb7185"/>
  </linearGradient>
  <linearGradient id="fireDeep" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#f97316"/><stop offset="1" stop-color="#be123c"/>
  </linearGradient>
</defs>''';

/// The mark: coloured parts masked by dark gaps (later parts carve a thin
/// gap into earlier ones; cuts carve lines), so it works on any background.
/// [mono] paints every part in one colour.
String markGroup({bool simple = false, String? mono, String id = 'm'}) {
  final parts = dragonParts().where((p) => !simple || p.simple).toList();
  final gapWidth = simple ? 10 : 6;
  final mask = parts
      .map(
        (p) => p.cut
            ? '<path d="${p.d}" fill="none" stroke="#000" stroke-width="$gapWidth" stroke-linecap="round" stroke-linejoin="round"/>'
            : '<path d="${p.d}" fill="#fff" stroke="#000" stroke-width="$gapWidth" stroke-linejoin="round"/>',
      )
      .join();
  final fills = parts
      .where((p) => !p.cut)
      .map((p) => '<path d="${p.d}" fill="${mono ?? p.fill}"/>')
      .join();
  return '<mask id="$id" maskUnits="userSpaceOnUse" x="0" y="0" width="512" height="512">'
      '<rect width="512" height="512" fill="#000"/>$mask</mask>'
      '<g mask="url(#$id)">$fills</g>';
}

/// App icon: dark rounded tile + mark.
String iconSvg({bool simple = false, int size = 512}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="$size" height="$size" role="img" aria-label="Daravel">'
    '${defs()}<rect width="512" height="512" rx="112" fill="url(#tile)"/>'
    '${simple ? '<g transform="translate(-36 -28) scale(1.14)">' : '<g>'}${markGroup(simple: simple)}</g></svg>';

/// Mark without tile (transparent).
String markSvg({String? mono, int size = 512}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="40 30 432 440" width="$size" height="${(size * 440 / 432).round()}" role="img" aria-label="Daravel">'
    '${defs()}${markGroup(mono: mono)}</svg>';

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
String horizontalSvg({required bool onDark, int height = 160}) {
  const h = 512.0;
  const textScale = 1.9;
  final width = 512 + 70 + wordmarkWidth * textScale;
  final text = onDark ? '#f8fafc' : navy;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${_n(width)} ${_n(h)}" '
      'width="${(height * width / h).round()}" height="$height" role="img" aria-label="Daravel">'
      '${defs()}<rect width="512" height="512" rx="112" fill="url(#tile)"/>${markGroup()}'
      '${wordmarkPaths(text, x: 582, y: h / 2 - 54 * textScale, scale: textScale)}</svg>';
}

/// GitHub/OpenGraph social preview (1280 × 640).
String socialSvg() =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640">'
    '${defs()}<rect width="1280" height="640" fill="$navyDeep"/>'
    '<g transform="translate(110 170) scale(0.586)"><rect width="512" height="512" rx="112" fill="url(#tile)"/>${markGroup(id: 's')}</g>'
    '${wordmarkPaths('#f8fafc', x: 470, y: 214, scale: 1.0)}'
    '<g fill="#94a3b8" font-family="Segoe UI, Inter, Helvetica, Arial, sans-serif" font-size="32">'
    '<text x="474" y="392">The Laravel experience,</text>'
    '<text x="474" y="436">compiled to a single native binary.</text></g></svg>';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final out = Directory('$root/docs/brand');
  final svgDir = Directory('${out.path}/svg')..createSync(recursive: true);
  final pngDir = Directory('${out.path}/png')..createSync(recursive: true);

  final svgs = <String, String>{
    'daravel-icon': iconSvg(),
    'daravel-icon-small': iconSvg(simple: true),
    'daravel-mark': markSvg(),
    'daravel-mark-mono-white': markSvg(mono: '#ffffff'),
    'daravel-mark-mono-navy': markSvg(mono: navy),
    'daravel-logo-horizontal-on-dark': horizontalSvg(onDark: true),
    'daravel-logo-horizontal-on-light': horizontalSvg(onDark: false),
    'daravel-social': socialSvg(),
  };
  for (final entry in svgs.entries) {
    File('${svgDir.path}/${entry.key}.svg')
        .writeAsStringSync('${entry.value}\n');
  }
  stdout.writeln('Wrote ${svgs.length} SVGs to docs/brand/svg');
  if (args.contains('--svg-only')) {
    return;
  }

  final renders = <({String name, String svg, int w, int h})>[
    for (final s in [16, 32, 48])
      (
        name: 'daravel-icon-$s',
        svg: iconSvg(simple: true, size: s),
        w: s,
        h: s,
      ),
    for (final s in [64, 128, 180, 192, 256, 512, 1024])
      (name: 'daravel-icon-$s', svg: iconSvg(size: s), w: s, h: s),
    for (final s in [128, 256, 512, 1024])
      (
        name: 'daravel-mark-$s',
        svg: markSvg(size: s),
        w: s,
        h: (s * 440 / 432).round(),
      ),
    for (final s in [256, 512])
      (
        name: 'daravel-mark-mono-white-$s',
        svg: markSvg(mono: '#ffffff', size: s),
        w: s,
        h: (s * 440 / 432).round(),
      ),
    for (final s in [256, 512])
      (
        name: 'daravel-mark-mono-navy-$s',
        svg: markSvg(mono: navy, size: s),
        w: s,
        h: (s * 440 / 432).round(),
      ),
    for (final h in [64, 128, 256])
      (
        name: 'daravel-logo-horizontal-on-dark-$h',
        svg: horizontalSvg(onDark: true, height: h),
        w: _hw(h),
        h: h,
      ),
    for (final h in [64, 128, 256])
      (
        name: 'daravel-logo-horizontal-on-light-$h',
        svg: horizontalSvg(onDark: false, height: h),
        w: _hw(h),
        h: h,
      ),
    (name: 'daravel-social-1280x640', svg: socialSvg(), w: 1280, h: 640),
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
  stdout.writeln('Rendered ${renders.length} PNGs to docs/brand/png');

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
    '/// The Daravel favicon (32 px PNG, simplified mark) as a data URI.\n'
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
