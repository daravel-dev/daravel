# Daravel brand assets

The Daravel mark is an infinity loop on a navy tile. Its blue loop stands for Dart, its red loop for the Laravel heritage, and the loop itself for an application that runs on both side by side and migrates either way. Gold floral ornament frames it.

The source of truth is the illustration `source/daravel-icon-source.jpg`. Every other file is generated from it by `tool/brand/generate.dart`: it finds the navy tile, crops it and gives it the icon's rounded corners, keys the transparent mark out of the navy background, and adds the stroke-built wordmark for the lockups. To change the logo, replace the source and regenerate. Do not edit the SVG or PNG files by hand.

```bash
dart run tool/brand/generate.dart            # SVG, PNG, favicon.ico, starter logo data
dart run tool/brand/generate.dart --svg-only # SVG only (no Chrome needed)
```

The lockups and the social preview are rendered with headless Chrome or Edge. Set `CHROME=/path/to/chrome` if it is not installed in the default location.

## Files

| Asset | Use |
| :-- | :-- |
| `svg/daravel-icon.svg` | Primary logo: the icon on its navy tile. README, docs, avatars. |
| `svg/daravel-icon-small.svg` | The same icon with a 128 px raster, lighter for 48 px and below. |
| `svg/daravel-mark.svg` | Mark without tile, transparent background. |
| `svg/daravel-mark-mono-white.svg`, `svg/daravel-mark-mono-navy.svg` | Single-colour silhouette for print, watermarks, embossing and one-colour contexts. |
| `svg/daravel-logo-horizontal-on-dark.svg`, `svg/daravel-logo-horizontal-on-light.svg` | Icon + wordmark lockup for headers and slides. |
| `svg/daravel-social.svg` | Social preview source (1280 × 640). |
| `png/daravel-icon-{16,32,48}.png` | Favicons. |
| `png/daravel-icon-{64,128,256,512,1024}.png` | Icons; 1024 for stores and print. |
| `png/daravel-icon-180.png`, `png/daravel-icon-192.png` | Apple touch icon and web app manifest. |
| `png/daravel-mark-{128,256,512,1024}.png` | Transparent mark. |
| `png/daravel-mark-mono-{white,navy}-{256,512}.png` | Single-colour mark. |
| `png/daravel-logo-horizontal-on-{dark,light}-{64,128,256}.png` | Lockups (height in px). |
| `png/daravel-social-1280x640.png` | GitHub social preview / Open Graph image. |
| `favicon.ico` | 16, 32 and 48 px frames. |

The SVGs wrap the generated rasters (a JPEG for the tile, a PNG for the transparent marks), so they scale in layouts but carry no more detail than the 512 px images. Use the PNGs at their own sizes where you can.

```html
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/daravel-icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/daravel-icon-180.png">
```

## Usage

- Keep clear space around the icon of at least one quarter of its width.
- On light backgrounds use the icon (it carries its own navy tile), `on-light` lockups or the navy mono mark. On dark backgrounds use the transparent mark, `on-dark` lockups or the white mono mark.
- The transparent colour mark is keyed out of a dark background: its soft edges suit dark and mid-tone backgrounds best. On white, prefer the icon.
- Do not recolour, rotate, stretch, add effects, or place the transparent colour mark on busy images.

## Palette

Sampled from the illustration:

| Role | Colours |
| :-- | :-- |
| Tile / navy | `#13345a` (top glow) → `#051430` → `#020b26`, text navy `#11133a` |
| Blue loop (Dart) | `#0f6dd9`, `#1472d0`, `#073983` |
| Red loop (Laravel heritage) | `#f4342d`, `#c02b2d` |
| Gold ornament | `#fdf38f`, `#fbd971` |

## Origin

The mark is a raster illustration supplied by the project owner in October 2026; it replaced the earlier geometric dragon. It deliberately contains no elements of other marks: no Flutter-style chevrons and no Laravel-style cube glyphs. The wordmark is built from strokes, not a font, so it renders identically everywhere.

## Trademarks and fair use

- Describe Daravel as **"a Laravel-inspired, AOT-native backend framework for Dart"**. Never
  present it as an official Laravel port or as "Laravel for Dart", and never imply endorsement
  by Laravel Holdings Inc. or Google LLC.
- Do not alter the Daravel mark to resemble the Laravel logo or the Dart or Flutter logos, and do
  not combine the Daravel mark with those logos in a single lockup.
- "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" and "Flutter" are trademarks of
  Google LLC. Mention them only to describe compatibility or inspiration (nominative fair use).
