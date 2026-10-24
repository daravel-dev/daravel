# Daravel brand assets

The Daravel mark is a geometric dragon. Its blue wing and head stand for Dart, and its red serpentine body stands for the Laravel heritage. All assets are generated from one source, `tool/brand/generate.dart`, where the mark is defined as geometry. Edit the geometry there and regenerate; do not edit the SVG or PNG files by hand.

```bash
dart run tool/brand/generate.dart            # SVG, PNG, favicon.ico, starter logo data
dart run tool/brand/generate.dart --svg-only # SVG only (no Chrome needed)
```

PNG rendering uses headless Chrome or Edge. Set `CHROME=/path/to/chrome` if it is not installed in the default location.

## Files

| Asset | Use |
| :-- | :-- |
| `svg/daravel-icon.svg` | Primary logo: app icon on the navy tile. README, docs, avatars. |
| `svg/daravel-icon-small.svg` | Simplified icon for 48 px and below (fewer facets, wider gaps). |
| `svg/daravel-mark.svg` | Mark without tile, transparent background. |
| `svg/daravel-mark-mono-white.svg`, `svg/daravel-mark-mono-navy.svg` | Single-colour mark for print, watermarks, embossing and one-colour contexts. |
| `svg/daravel-logo-horizontal-on-dark.svg`, `svg/daravel-logo-horizontal-on-light.svg` | Icon + wordmark lockup for headers and slides. |
| `svg/daravel-social.svg` | Social preview source (1280 × 640). |
| `png/daravel-icon-{16,32,48}.png` | Favicons (simplified mark). |
| `png/daravel-icon-{64,128,256,512,1024}.png` | Icons; 1024 for stores and print. |
| `png/daravel-icon-180.png`, `png/daravel-icon-192.png` | Apple touch icon and web app manifest. |
| `png/daravel-mark-{128,256,512,1024}.png` | Transparent mark. |
| `png/daravel-mark-mono-{white,navy}-{256,512}.png` | Single-colour mark. |
| `png/daravel-logo-horizontal-on-{dark,light}-{64,128,256}.png` | Lockups (height in px). |
| `png/daravel-social-1280x640.png` | GitHub social preview / Open Graph image. |
| `favicon.ico` | 16, 32 and 48 px frames. |

```html
<link rel="icon" href="/favicon.ico" sizes="48x48">
<link rel="icon" href="/daravel-icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/daravel-icon-180.png">
```

## Usage

- Keep clear space around the icon of at least one quarter of its width.
- Use `daravel-icon-small` for 48 px and below; the full mark loses detail there.
- On light backgrounds use the icon (it carries its own navy tile), `on-light` lockups or the navy mono mark. On dark backgrounds use the transparent mark, `on-dark` lockups or the white mono mark.
- Do not recolour, rotate, stretch, add effects, or place the transparent colour mark on busy images.

## Palette

| Role | Colours |
| :-- | :-- |
| Tile / navy | `#161a4a` → `#0b0d2a`, text navy `#11133a` |
| Ice (wing, head) | `#a5f3fc`, `#67e8f9`, `#38bdf8`, `#0ea5e9`, `#2563eb`, `#1d4ed8`, `#1e3a8a` |
| Fire (body, mane, fin) | `#fdba74`, `#fb923c`, `#ef4444`, `#e11d48`, `#be123c` |
| Accent | `#6d28d9` → `#4c1d95` |

## Origin

The mark was drawn from scratch as vector geometry, using the project owner's dragon sketches as composition references. It deliberately contains no elements of other marks: no Flutter-style chevrons and no Laravel-style cube glyphs. The wordmark is built from strokes, not a font, so it renders identically everywhere.
