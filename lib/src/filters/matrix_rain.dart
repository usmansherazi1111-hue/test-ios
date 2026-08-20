// The falling-code backdrop for demos/threejs/matrix.
//
// The demo ships `matrixRain.mp4`, 6.5 MB of H.264, and hands it to three as a
// `VideoTexture`. That cannot be reproduced here, and not for want of a video
// plugin: the shader samples the rain at *refracted* UVs, per fragment, and the
// renderer is a software rasteriser. It needs the pixels on the CPU every
// frame. `video_player` hands back a platform texture that only the GPU can
// read, and there is no Flutter API that decodes a frame into memory. Shipping
// the mp4 as a sprite sheet would need an H.264 decoder to build it.
//
// So the rain is synthesised instead. This is the one place in the port where
// the imagery is not the demo's own, and it is a fair trade: the effect is
// famously easy to generate, it costs no asset at all, and what the shader
// actually wants from it is a mostly-black field with bright green columns —
// which is what this produces.
//
// Everything about the *effect* — the refraction, the green key, the neck fade,
// the compositing — is still a straight transcription. Only the source imagery
// differs.

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/texture.dart';

/// A procedural falling-code texture, regenerated every frame.
///
/// Reuses one pixel buffer and one [Texture2D] across frames, so a 30 fps
/// stream does not churn the heap.
class MatrixRain {
  MatrixRain({
    this.columns = 22,
    this.rows = 26,
    this.cellWidth = 6,
    this.cellHeight = 10,
    int seed = 0x4D41545258,
  }) : _rng = math.Random(seed) {
    _pixels = Uint8List(width * height * 4);
    texture = Texture2D(width, height, _pixels);
    _glyphs = _buildGlyphs(_rng);
    _columns = List<_Column>.generate(columns, (i) => _spawn(above: true));
  }

  final int columns, rows;

  /// Glyph cell in texels. A 5x7 pattern in a 6x10 cell leaves a one-texel gap
  /// on the right and three below, which is what gives the column its rhythm.
  final int cellWidth, cellHeight;

  int get width => columns * cellWidth;
  int get height => rows * cellHeight;

  /// The live texture. The same object every frame — its pixels are rewritten
  /// in place, so hold the reference, not a copy.
  late final Texture2D texture;

  late final Uint8List _pixels;
  final math.Random _rng;
  late final List<Uint8List> _glyphs;
  late final List<_Column> _columns;

  /// Matrix green, and the near-white leading character.
  static const List<double> kTrailColor = <double>[0.0, 1.0, 0.18];
  static const List<double> kHeadColor = <double>[0.72, 1.0, 0.80];

  /// How many glyphs trail behind the head, as a fraction of [rows].
  static const double kMinTailFraction = 0.35;
  static const double kMaxTailFraction = 1.1;

  /// Cells per second.
  static const double kMinSpeed = 3.0;
  static const double kMaxSpeed = 11.0;

  /// Chance per second that a given visible cell swaps to another glyph. The
  /// flicker is what stops the columns reading as solid bars.
  static const double kMutationsPerSecond = 6.0;

  double _elapsed = 0;

  /// Seconds of rain generated so far, for tests.
  double get elapsed => _elapsed;

  /// Advances by [dt] seconds and rewrites [texture]'s pixels.
  void update(double dt) {
    if (dt < 0) dt = 0;
    _elapsed += dt;

    for (final c in _columns) {
      c.head += c.speed * dt;
      // Respawn once the whole tail has cleared the bottom.
      if (c.head - c.tail > rows) {
        final fresh = _spawn(above: false);
        c
          ..head = fresh.head
          ..speed = fresh.speed
          ..tail = fresh.tail
          ..glyphs = fresh.glyphs;
        continue;
      }
      // Mutate a cell or two.
      var budget = kMutationsPerSecond * dt;
      while (budget > 0) {
        if (budget < 1.0 && _rng.nextDouble() > budget) break;
        c.glyphs[_rng.nextInt(rows)] = _rng.nextInt(_glyphs.length);
        budget -= 1.0;
      }
    }

    _paint();
  }

  _Column _spawn({required bool above}) {
    final tail = (rows *
            (kMinTailFraction +
                _rng.nextDouble() * (kMaxTailFraction - kMinTailFraction)))
        .round();
    return _Column(
      // A fresh column starts above the top so it falls in; the very first
      // batch is scattered through the whole drop so the screen is not empty
      // for the first second.
      head: above
          ? -_rng.nextDouble() * rows
          : -tail * _rng.nextDouble() - 1.0,
      speed: kMinSpeed + _rng.nextDouble() * (kMaxSpeed - kMinSpeed),
      tail: tail,
      glyphs: List<int>.generate(rows, (_) => _rng.nextInt(_glyphs.length)),
    );
  }

  void _paint() {
    _pixels.fillRange(0, _pixels.length, 0);
    // Opaque: the rain is a background, and the framebuffer is premultiplied.
    for (var i = 3; i < _pixels.length; i += 4) {
      _pixels[i] = 255;
    }

    for (var c = 0; c < columns; c++) {
      final col = _columns[c];
      final headRow = col.head.floor();
      final x0 = c * cellWidth;

      for (var d = 0; d <= col.tail; d++) {
        final r = headRow - d;
        if (r < 0 || r >= rows) continue;

        // Linear fade behind the head, and the head itself pale.
        final t = 1.0 - d / col.tail;
        final isHead = d == 0;
        final rgb = isHead ? kHeadColor : kTrailColor;
        final k = isHead ? 1.0 : t * t;
        if (k <= 0.004) continue;

        _blitGlyph(_glyphs[col.glyphs[r]], x0, r * cellHeight, rgb, k);
      }
    }
  }

  void _blitGlyph(
      Uint8List glyph, int x0, int y0, List<double> rgb, double k) {
    for (var gy = 0; gy < _kGlyphH; gy++) {
      final y = y0 + gy;
      if (y >= height) break;
      final rowBits = glyph[gy];
      if (rowBits == 0) continue;
      for (var gx = 0; gx < _kGlyphW; gx++) {
        if ((rowBits & (1 << gx)) == 0) continue;
        final x = x0 + gx;
        if (x >= width) break;
        final i = (y * width + x) * 4;
        // Max, not add: overlapping columns must not blow out to white.
        final r = (rgb[0] * k * 255).round().clamp(0, 255);
        final g = (rgb[1] * k * 255).round().clamp(0, 255);
        final b = (rgb[2] * k * 255).round().clamp(0, 255);
        if (r > _pixels[i]) _pixels[i] = r;
        if (g > _pixels[i + 1]) _pixels[i + 1] = g;
        if (b > _pixels[i + 2]) _pixels[i + 2] = b;
      }
    }
  }

  static const int _kGlyphW = 5;
  static const int _kGlyphH = 7;

  /// A fixed set of 5x7 dot-matrix glyphs, one byte per row, bit 0 = leftmost.
  ///
  /// Generated rather than rasterised from a font on purpose. Real glyphs would
  /// mean `ParagraphBuilder` and a `toByteData` round trip at load, a
  /// dependency on which characters the platform font actually has, and a test
  /// suite that behaves differently under the test font. At this size — refracted,
  /// green, behind a face — glyph identity is not visible; density and rhythm
  /// are. So each glyph is a random pattern with two constraints that make it
  /// read as writing rather than as noise: no empty rows, and a lit column down
  /// the middle to give it a stroke.
  static List<Uint8List> _buildGlyphs(math.Random rng) {
    const count = 40;
    final out = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final g = Uint8List(_kGlyphH);
      for (var y = 0; y < _kGlyphH; y++) {
        var bits = 0;
        for (var x = 0; x < _kGlyphW; x++) {
          if (rng.nextDouble() < 0.45) bits |= 1 << x;
        }
        // A spine, so the glyph has a stroke instead of dissolving.
        bits |= 1 << 2;
        g[y] = bits;
      }
      out.add(g);
    }
    return out;
  }
}

class _Column {
  _Column({
    required this.head,
    required this.speed,
    required this.tail,
    required this.glyphs,
  });

  /// Position of the leading glyph, in cells from the top. Starts negative.
  double head;
  double speed;
  int tail;
  List<int> glyphs;
}
