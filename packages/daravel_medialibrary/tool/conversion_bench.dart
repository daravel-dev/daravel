// TEMPORARY: measures the conversion work model on the CI runner (the
// reference machine). Removed before the pull request is ready.
//
//   dart compile exe tool/conversion_bench.dart -o build/bench
//   build/bench [cells|chains|random|all] [--repeat=3] [--random=40]
//
// Prints, per case, the model's units, the measured milliseconds of each
// repetition, their spread and measured/model; then the largest ratio.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:daravel_medialibrary/daravel_medialibrary.dart';
import 'package:daravel_medialibrary/src/conversion_plan.dart';
import 'package:image/image.dart' as img;

const int _budget = MediaLibraryConfig.defaultMaxConversionWork;
const int _growth = MediaLibraryConfig.defaultMaxImagePixels ~/ 4;
final List<String> _summary = [];
var _largest = 0.0;
var _largestName = '';

/// An image of [kind] with varied content (a gradient with noise), as the
/// measurements on the developer machine used.
img.Image rich(PixelKind kind, int w, int h, {int frames = 1}) {
  img.Image one(int seedBase) {
    final (format, channels, palette) = switch (kind) {
      PixelKind.gray8 => (img.Format.uint8, 1, false),
      PixelKind.grayAlpha8 => (img.Format.uint8, 2, false),
      PixelKind.rgb8 => (img.Format.uint8, 3, false),
      PixelKind.rgba8 => (img.Format.uint8, 4, false),
      PixelKind.gray16 => (img.Format.uint16, 1, false),
      PixelKind.grayAlpha16 => (img.Format.uint16, 2, false),
      PixelKind.rgb16 => (img.Format.uint16, 3, false),
      PixelKind.rgba16 => (img.Format.uint16, 4, false),
      PixelKind.palette8 => (img.Format.uint8, 3, true),
      _ => throw ArgumentError('$kind'),
    };
    final image = img.Image(
      width: w,
      height: h,
      format: format,
      numChannels: channels,
      withPalette: palette,
    );
    if (palette) {
      final p = image.palette!;
      final r = math.Random(seedBase);
      for (var i = 0; i < p.numColors; i++) {
        p.setRgb(i, r.nextInt(256), r.nextInt(256), r.nextInt(256));
      }
    }
    var seed = 12345 + seedBase;
    for (final px in image) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      if (palette) {
        px.index = ((px.x * 7 + px.y * 3) ~/ 5 + seed % 5) % 256;
        continue;
      }
      final max = px.maxChannelValue.toInt();
      final n = seed % 64;
      px
        ..r = ((px.x * max ~/ w) + n * max ~/ 255) % (max + 1)
        ..g = ((px.y * max ~/ h) + 2 * n * max ~/ 255) % (max + 1)
        ..b =
            (((px.x + px.y) * max ~/ (w + h)) + 3 * n * max ~/ 255) % (max + 1);
      if (channels == 2 || channels == 4) {
        px.a = max - (n * max ~/ 255);
      }
    }
    return image;
  }

  final first = one(0);
  for (var i = 1; i < frames; i++) {
    first.addFrame(one(i));
  }
  return first;
}

ImageShape shapeOf(img.Image image, PixelKind kind) => (
  width: image.width,
  height: image.height,
  frames: image.numFrames,
  kind: kind,
);

/// Runs [body] [repeat] times; reports against [model] units.
void measure(String name, double model, int repeat, void Function() body) {
  final times = <double>[];
  for (var i = 0; i < repeat; i++) {
    final watch = Stopwatch()..start();
    body();
    times.add(watch.elapsedMicroseconds / 1000);
  }
  final sorted = [...times]..sort();
  final median = sorted[sorted.length ~/ 2];
  final spread = (sorted.last - sorted.first) / median * 100;
  final ratio = median / model;
  if (ratio > _largest) {
    _largest = ratio;
    _largestName = name;
  }
  final line =
      '| $name | ${model.toStringAsFixed(0)} | '
      '${times.map((t) => t.toStringAsFixed(0)).join(' / ')} | '
      '${spread.toStringAsFixed(0)} % | ${ratio.toStringAsFixed(2)} |';
  print(line);
  _summary.add(line);
}

void header(String title) {
  final lines = [
    '',
    '### $title',
    '',
    '| case | model units | ms (each run) | spread | median ms / model |',
    '|---|---|---|---|---|',
  ];
  lines.forEach(print);
  _summary.addAll(lines);
}

/// The twelve largest rows a conversion can reach (a manipulated 16-bit
/// image is made 8-bit first, so its resize and blur rows never run),
/// each step alone on an image of about 1 to 4 MP.
void cells(int repeat) {
  header('a) control cells: one step alone');
  void cell(
    String name,
    PixelKind kind,
    int w,
    int h,
    ConversionStep Function(ImageShape before) step,
    void Function(img.Image image) run,
  ) {
    final image = rich(kind, w, h);
    final before = shapeOf(image, kind);
    measure(name, stepCost(step(before), before)!, repeat, () => run(image));
  }

  ImageShape sized(ImageShape s, int w, int h, [PixelKind? kind]) =>
      (width: w, height: h, frames: s.frames, kind: kind ?? s.kind);

  for (final kind in [PixelKind.grayAlpha8, PixelKind.rgb8, PixelKind.rgba8]) {
    cell(
      'encode gif ${kind.name} 1 MP',
      kind,
      1000,
      1000,
      (s) => Encode(s, ImageFormat.gif, null),
      (i) => img.encodeGif(i),
    );
  }
  cell(
    'canvas rgb8 2 MP on 2.5 MP',
    PixelKind.rgb8,
    1414,
    1414,
    (s) => Canvas(sized(s, 1581, 1581), s),
    (i) {
      final page = img.Image(width: 1581, height: 1581);
      img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
      img.compositeImage(page, i, dstX: 83, dstY: 83);
    },
  );
  cell(
    'blur rgba8 r25 1 MP',
    PixelKind.rgba8,
    1000,
    1000,
    (s) => Blur(s, 25),
    (i) => img.gaussianBlur(i, radius: 25),
  );
  cell(
    'blur rgb8 r15 1 MP',
    PixelKind.rgb8,
    1000,
    1000,
    (s) => Blur(s, 15),
    (i) => img.gaussianBlur(i, radius: 15),
  );
  for (final kind in [PixelKind.rgba8, PixelKind.rgb8, PixelKind.grayAlpha8]) {
    cell(
      'resize ${kind.name} 1 MP to 4 MP',
      kind,
      1000,
      1000,
      (s) => Resize(sized(s, 2000, 2000)),
      (i) => img.copyResize(
        i,
        width: 2000,
        height: 2000,
        interpolation: img.Interpolation.cubic,
      ),
    );
  }
  cell(
    'encode png rgb16 4 MP',
    PixelKind.rgb16,
    2000,
    2000,
    (s) => Encode(s, ImageFormat.png, null),
    (i) => img.encodePng(i),
  );
  cell(
    'encode png rgb8 4 MP',
    PixelKind.rgb8,
    2000,
    2000,
    (s) => Encode(s, ImageFormat.png, null),
    (i) => img.encodePng(i),
  );
  cell(
    'encode jpg rgb16 4 MP',
    PixelKind.rgb16,
    2000,
    2000,
    (s) => Encode(s, ImageFormat.jpg, 75),
    (i) => img.encodeJpg(i, quality: 75),
  );
}

typedef Chain = ({
  String name,
  Uint8List bytes,
  ImageContainer container,
  ImageShape shape,
  Map<String, List<Object?>> manipulations,
});

double? modelOf(Chain chain) {
  try {
    return conversionCost(
      chain.container,
      chain.shape,
      planConversion(
        chain.shape,
        chain.manipulations,
        growth: _growth,
        maxSide: 65535,
      ),
      orient: true,
    );
  } on ImageConversionException {
    return null;
  }
}

void runChain(Chain chain, int repeat) {
  final model = modelOf(chain)!;
  measure(chain.name, model, repeat, () {
    convertImageSync(chain.bytes, chain.manipulations, maxWork: 1 << 40);
  });
}

Chain pngChain(
  String name,
  PixelKind kind,
  int w,
  int h,
  Map<String, List<Object?>> manipulations,
) {
  final image = rich(kind, w, h);
  return (
    name: name,
    bytes: img.encodePng(image),
    container: ImageContainer.png,
    shape: shapeOf(image, kind),
    manipulations: manipulations,
  );
}

/// The six whole conversions measured on the developer machine.
void chains(int repeat) {
  header('b) six whole conversions');
  runChain(
    pngChain('reviewer chain', PixelKind.rgb8, 100, 100, {
      'width': [3162],
      'height': [3161],
      'crop': [3160, 3160, 'center'],
      'fit': ['fill', 2000, 1999],
      'blur': [30],
      'format': ['gif'],
    }),
    repeat,
  );
  runChain(
    pngChain('w3162-png', PixelKind.rgb8, 100, 100, {
      'width': [3162],
      'format': ['png'],
    }),
    repeat,
  );
  runChain(
    pngChain('w3162-h2000-blur30-gif', PixelKind.rgb8, 100, 100, {
      'width': [3162],
      'height': [2000],
      'blur': [30],
      'format': ['gif'],
    }),
    repeat,
  );
  runChain(
    pngChain('png16-10mp-w1581-png', PixelKind.rgb16, 4000, 2500, {
      'width': [1581],
      'format': ['png'],
    }),
    repeat,
  );
  final photo = rich(PixelKind.rgb8, 8000, 5000);
  runChain((
    name: 'jpg40mp-w3162-jpg',
    bytes: img.encodeJpg(photo, quality: 90),
    container: ImageContainer.jpeg,
    shape: shapeOf(photo, PixelKind.rgb8),
    manipulations: {
      'width': [3162],
    },
  ), repeat);
  runChain(
    pngChain('png8-w2000-blur20-gif', PixelKind.rgb8, 100, 100, {
      'width': [2000],
      'blur': [20],
      'format': ['gif'],
    }),
    repeat,
  );
}

/// [count] chains from the manipulation grammar (input format x 1 to 6
/// steps x output format) that the model lets through, seeded.
void random(int repeat, int count) {
  header('c) $count random chains the model lets through (seed 406)');
  final r = math.Random(406);
  int side() => 100 + r.nextInt(2400);
  Map<String, List<Object?>> manipulations() {
    final m = <String, List<Object?>>{};
    final names = ['width', 'height', 'fit', 'crop', 'greyscale', 'blur']
      ..shuffle(r);
    for (final name in names.take(1 + r.nextInt(6))) {
      m[name] = switch (name) {
        'width' || 'height' => [100 + r.nextInt(3000)],
        'fit' => [
          Fit.values[r.nextInt(Fit.values.length)].name,
          side(),
          side(),
        ],
        'crop' => [
          side(),
          side(),
          CropPosition.values[r.nextInt(CropPosition.values.length)].name,
        ],
        'greyscale' => <Object?>[],
        _ => [1 + r.nextInt(60)],
      };
    }
    m['format'] = [
      ['jpg', 'png', 'gif'][r.nextInt(3)],
    ];
    return m;
  }

  var made = 0;
  var tried = 0;
  while (made < count && tried < 100000) {
    tried++;
    final w = side();
    final h = side();
    final which = r.nextInt(8);
    final m = manipulations();
    final ImageContainer container;
    final PixelKind kind;
    var frames = 1;
    switch (which) {
      case 0 || 1:
        (container, kind) = (ImageContainer.png, PixelKind.rgb8);
      case 2:
        (container, kind) = (ImageContainer.png, PixelKind.rgba8);
      case 3:
        (container, kind) = (ImageContainer.png, PixelKind.gray8);
      case 4:
        (container, kind) = (ImageContainer.png, PixelKind.rgb16);
      case 5:
        (container, kind) = (ImageContainer.jpeg, PixelKind.rgb8);
      case 6:
        (container, kind) = (ImageContainer.gif, PixelKind.palette8);
        frames = 1 + r.nextInt(5);
      default:
        (container, kind) = (ImageContainer.bmp, PixelKind.rgb8);
    }
    final shape = (width: w, height: h, frames: frames, kind: kind);
    final model = modelOf((
      name: '',
      bytes: Uint8List(0),
      container: container,
      shape: shape,
      manipulations: m,
    ));
    if (model == null || model > _budget) {
      continue;
    }
    final image = rich(kind, w, h, frames: frames);
    final bytes = switch (container) {
      ImageContainer.png => img.encodePng(image),
      ImageContainer.jpeg => img.encodeJpg(image, quality: 90),
      ImageContainer.gif => img.encodeGif(image),
      _ => img.encodeBmp(image),
    };
    made++;
    runChain((
      name:
          '#$made ${container.name} ${kind.name} ${w}x$h'
          '${frames > 1 ? 'x$frames' : ''} $m',
      bytes: bytes,
      container: container,
      shape: shape,
      manipulations: m,
    ), repeat);
  }
}

void main(List<String> args) {
  final mode = args.firstWhere((a) => !a.startsWith('--'), orElse: () => 'all');
  int option(String name, int fallback) {
    for (final a in args) {
      if (a.startsWith('--$name=')) {
        return int.parse(a.substring(name.length + 3));
      }
    }
    return fallback;
  }

  final repeat = option('repeat', 3);
  print(
    'conversion bench: ${Platform.operatingSystem} '
    '${Platform.numberOfProcessors} CPUs, Dart ${Platform.version}',
  );
  if (mode == 'cells' || mode == 'all') {
    cells(repeat);
  }
  if (mode == 'chains' || mode == 'all') {
    chains(repeat);
  }
  if (mode == 'random' || mode == 'all') {
    random(repeat, option('random', 40));
  }
  final last =
      'Largest median/model: ${_largest.toStringAsFixed(2)} ($_largestName)';
  print('\n$last');
  _summary
    ..add('')
    ..add(last);
  final out = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (out != null && out.isNotEmpty) {
    File(out)
        .writeAsStringSync('${_summary.join('\n')}\n', mode: FileMode.append);
  }
}
