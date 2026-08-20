// CPU-sampled textures.
//
// Two flavours, sharing one bilinear fetch:
//
//   * [Texture2D] — an ordinary UV-mapped image (the tiger's headTexture2.png).
//   * [EquirectTexture] — the same pixels addressed by a *direction*, which is
//     how glassesVTO's env map is read.
//
// Everything here is deliberately CPU-side: the rasteriser in src/render/ has
// no GPU to hand the sampling to.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

/// How UVs outside 0..1 are handled. three's defaults are clamp for a loaded
/// texture and repeat for a generated one; both are here because the tiger
/// head clamps and tiled patterns would not.
enum TextureWrap { clamp, repeat }

class Texture2D {
  Texture2D(this.width, this.height, this.rgba, {this.wrap = TextureWrap.clamp})
      : assert(rgba.length >= width * height * 4);

  final int width, height;

  /// Straight (un-premultiplied) RGBA8888, row-major from the top.
  final Uint8List rgba;

  TextureWrap wrap;

  /// A single-colour texture. `white.png` in the tiger demo is literally a 1x1
  /// white pixel, so this covers it without a decode.
  factory Texture2D.solid(int r, int g, int b, [int a = 255]) =>
      Texture2D(1, 1, Uint8List.fromList([r, g, b, a]));

  /// Decodes encoded image bytes (PNG/JPEG).
  ///
  /// [maxWidth] downsamples at decode time. The tiger's 1024x1024 head texture
  /// is far more than a face-sized object needs on a phone, and the cost here
  /// is per-fragment cache pressure, not just memory.
  static Future<Texture2D> decode(Uint8List encoded,
      {int? maxWidth, TextureWrap wrap = TextureWrap.clamp}) async {
    final codec = await ui.instantiateImageCodec(encoded, targetWidth: maxWidth);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final t = Texture2D(
        image.width, image.height, bytes!.buffer.asUint8List(),
        wrap: wrap);
    image.dispose();
    codec.dispose();
    return t;
  }

  static Future<Texture2D> load(String assetKey,
      {int? maxWidth, TextureWrap wrap = TextureWrap.clamp}) async {
    final data = await rootBundle.load(assetKey);
    return decode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        maxWidth: maxWidth,
        wrap: wrap);
  }

  /// Bilinear fetch. Writes RGBA as 0..1 into [out] (length >= 4).
  ///
  /// [v] follows the GL convention: 0 at the *bottom* of the image.
  void sample(double u, double v, Float64List out) {
    _sampleRaw(u, 1.0 - v, out);
  }

  /// Same, but [v] measured from the top — what a viewport-space lookup wants.
  void sampleTopDown(double u, double v, Float64List out) {
    _sampleRaw(u, v, out);
  }

  void _sampleRaw(double u, double vTop, Float64List out) {
    // Flat textures are common enough to be worth skipping the whole bilinear
    // dance for: the tiger's eye material is `white.png`, a single pixel, and
    // it covers a good fraction of the mask.
    if (width == 1 && height == 1) {
      const inv = 1.0 / 255.0;
      out[0] = rgba[0] * inv;
      out[1] = rgba[1] * inv;
      out[2] = rgba[2] * inv;
      out[3] = rgba[3] * inv;
      return;
    }

    double x, y;
    if (wrap == TextureWrap.repeat) {
      x = (u - u.floorToDouble()) * width - 0.5;
      y = (vTop - vTop.floorToDouble()) * height - 0.5;
    } else {
      x = (u < 0 ? 0.0 : (u > 1 ? 1.0 : u)) * width - 0.5;
      y = (vTop < 0 ? 0.0 : (vTop > 1 ? 1.0 : vTop)) * height - 0.5;
    }

    final x0f = x.floorToDouble(), y0f = y.floorToDouble();
    final fx = x - x0f, fy = y - y0f;

    final x0 = _wrapIndex(x0f.toInt(), width);
    final x1 = _wrapIndex(x0f.toInt() + 1, width);
    final y0 = _wrapIndex(y0f.toInt(), height);
    final y1 = _wrapIndex(y0f.toInt() + 1, height);

    final i00 = (y0 * width + x0) * 4;
    final i10 = (y0 * width + x1) * 4;
    final i01 = (y1 * width + x0) * 4;
    final i11 = (y1 * width + x1) * 4;

    final w00 = (1 - fx) * (1 - fy);
    final w10 = fx * (1 - fy);
    final w01 = (1 - fx) * fy;
    final w11 = fx * fy;

    const inv = 1.0 / 255.0;
    for (var c = 0; c < 4; c++) {
      out[c] = (rgba[i00 + c] * w00 +
              rgba[i10 + c] * w10 +
              rgba[i01 + c] * w01 +
              rgba[i11 + c] * w11) *
          inv;
    }
  }

  int _wrapIndex(int i, int n) {
    if (wrap == TextureWrap.repeat) {
      var k = i % n;
      if (k < 0) k += n;
      return k;
    }
    return i < 0 ? 0 : (i > n - 1 ? n - 1 : i);
  }
}

/// Equirectangular environment map, addressed by direction.
///
/// The glasses are lit *entirely* by this image — glassesVTO adds no lights at
/// all, so every pixel of the frames is a reflection of envMap.jpg and nothing

/// A six-face cube map with a mip pyramid.
///
/// three's `CubeTextureLoader` produces one of these from six images, and
/// `WebGLTextures` builds its mipmaps because the faces are power-of-two.
/// `MeshStandardMaterial` then samples it at a roughness-dependent level —
/// see `getSpecularMIPLevel` — so a rough surface reflects a blurred
/// environment and a polished one reflects a sharp one. That blur pyramid is
/// the whole reason this is not just six `Texture2D`s.
class CubeTexture {
  CubeTexture._(this.size, this._levels);

  /// Edge length of level 0, in texels.
  final int size;

  /// `_levels[l][face]` — face order is three's: +X, -X, +Y, -Y, +Z, -Z.
  final List<List<Uint8List>> _levels;

  /// Highest mip index, `log2(size)`. three's `__maxMipLevel`.
  int get maxMipLevel => _levels.length - 1;

  /// Number of mip levels, including level 0.
  int get levelCount => _levels.length;

  /// Edge length of level [l].
  int sizeOf(int l) => size >> l;

  /// Builds from six RGBA face images, all square and the same size.
  ///
  /// Face order is +X, -X, +Y, -Y, +Z, -Z — the order `CubeTextureLoader`
  /// takes its urls in, and the order the demo lists posx..negz.
  factory CubeTexture.fromFaces(int size, List<Uint8List> faces) {
    if (faces.length != 6) {
      throw ArgumentError('a cube map needs 6 faces, got ${faces.length}');
    }
    for (final f in faces) {
      if (f.length < size * size * 4) {
        throw ArgumentError('face is smaller than ${size}x$size RGBA');
      }
    }

    final levels = <List<Uint8List>>[faces];
    var n = size;
    while (n > 1) {
      final prev = levels.last;
      final half = n >> 1;
      levels.add(<Uint8List>[
        for (final face in prev) _downsample(face, n, half),
      ]);
      n = half;
    }
    return CubeTexture._(size, levels);
  }

  /// A single-colour cube, so a scene renders before the real map decodes.
  factory CubeTexture.solid(int r, int g, int b) => CubeTexture.fromFaces(
        1,
        List<Uint8List>.generate(
            6, (_) => Uint8List.fromList(<int>[r, g, b, 255])),
      );

  /// Decodes six encoded images into a cube.
  ///
  /// [maxWidth] caps the face size; 1024x1024 faces are far more than a
  /// software rasteriser can use, and the pyramid costs another third on top.
  static Future<CubeTexture> decodeFaces(List<Uint8List> encoded,
      {int maxWidth = 128}) async {
    final faces = <Uint8List>[];
    var size = 0;
    for (final bytes in encoded) {
      final t = await Texture2D.decode(bytes, maxWidth: maxWidth);
      if (t.width != t.height) {
        throw StateError('cube faces must be square, got ${t.width}x${t.height}');
      }
      size = t.width;
      faces.add(t.rgba);
    }
    return CubeTexture.fromFaces(size, faces);
  }

  /// Samples along [dx], [dy], [dz] at mip [level], writing RGB into [out].
  ///
  /// [level] is fractional and blended between the two neighbouring mips, as
  /// `textureCubeLodEXT` does.
  void sampleDirection(
      double dx, double dy, double dz, double level, Float64List out) {
    var l = level;
    if (l < 0) l = 0;
    final maxL = maxMipLevel.toDouble();
    if (l > maxL) l = maxL;

    final l0 = l.floor();
    final frac = l - l0;
    _sampleLevel(dx, dy, dz, l0, out);
    if (frac <= 1e-6 || l0 >= maxMipLevel) return;

    final hi = Float64List(3);
    _sampleLevel(dx, dy, dz, l0 + 1, hi);
    out[0] += (hi[0] - out[0]) * frac;
    out[1] += (hi[1] - out[1]) * frac;
    out[2] += (hi[2] - out[2]) * frac;
  }

  /// The standard cube-map face selection: the largest-magnitude axis picks the
  /// face, the other two divided by it give the texel.
  void _sampleLevel(
      double dx, double dy, double dz, int level, Float64List out) {
    final ax = dx.abs(), ay = dy.abs(), az = dz.abs();

    int face;
    double sc, tc, ma;
    if (ax >= ay && ax >= az) {
      ma = ax;
      if (dx > 0) {
        face = 0; // +X
        sc = -dz;
        tc = -dy;
      } else {
        face = 1; // -X
        sc = dz;
        tc = -dy;
      }
    } else if (ay >= az) {
      ma = ay;
      if (dy > 0) {
        face = 2; // +Y
        sc = dx;
        tc = dz;
      } else {
        face = 3; // -Y
        sc = dx;
        tc = -dz;
      }
    } else {
      ma = az;
      if (dz > 0) {
        face = 4; // +Z
        sc = dx;
        tc = -dy;
      } else {
        face = 5; // -Z
        sc = -dx;
        tc = -dy;
      }
    }

    if (ma < 1e-12) ma = 1e-12;
    final u = 0.5 * (sc / ma + 1.0);
    final v = 0.5 * (tc / ma + 1.0);

    _bilinear(_levels[level][face], size >> level, u, v, out);
  }

  static void _bilinear(
      Uint8List px, int n, double u, double v, Float64List out) {
    var x = (u.clamp(0.0, 1.0)) * n - 0.5;
    var y = (v.clamp(0.0, 1.0)) * n - 0.5;
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    final x0f = x.floorToDouble(), y0f = y.floorToDouble();
    final fx = x - x0f, fy = y - y0f;

    var x0 = x0f.toInt(), y0 = y0f.toInt();
    if (x0 > n - 1) x0 = n - 1;
    if (y0 > n - 1) y0 = n - 1;
    final x1 = x0 + 1 > n - 1 ? n - 1 : x0 + 1;
    final y1 = y0 + 1 > n - 1 ? n - 1 : y0 + 1;

    final i00 = (y0 * n + x0) * 4;
    final i10 = (y0 * n + x1) * 4;
    final i01 = (y1 * n + x0) * 4;
    final i11 = (y1 * n + x1) * 4;

    const inv = 1.0 / 255.0;
    for (var k = 0; k < 3; k++) {
      final top = px[i00 + k] + (px[i10 + k] - px[i00 + k]) * fx;
      final bot = px[i01 + k] + (px[i11 + k] - px[i01 + k]) * fx;
      out[k] = (top + (bot - top) * fy) * inv;
    }
  }

  /// A 2x2 box filter, which is what `generateMipmap` does.
  static Uint8List _downsample(Uint8List src, int n, int half) {
    final out = Uint8List(half * half * 4);
    for (var y = 0; y < half; y++) {
      for (var x = 0; x < half; x++) {
        final a = ((y * 2) * n + x * 2) * 4;
        final b = ((y * 2) * n + x * 2 + 1) * 4;
        final c = ((y * 2 + 1) * n + x * 2) * 4;
        final d = ((y * 2 + 1) * n + x * 2 + 1) * 4;
        final o = (y * half + x) * 4;
        for (var k = 0; k < 4; k++) {
          out[o + k] = (src[a + k] + src[b + k] + src[c + k] + src[d + k] + 2) >> 2;
        }
      }
    }
    return out;
  }
}

/// else. Get the sampling wrong and the frames turn into flat silhouettes.
class EquirectTexture extends Texture2D {
  EquirectTexture(super.width, super.height, super.rgba)
      : super(wrap: TextureWrap.repeat);

  static Future<EquirectTexture> decode(Uint8List encoded,
      {int maxWidth = 512}) async {
    final t = await Texture2D.decode(encoded, maxWidth: maxWidth);
    return EquirectTexture(t.width, t.height, t.rgba);
  }

  static Future<EquirectTexture> load(String assetKey,
      {int maxWidth = 512}) async {
    final data = await rootBundle.load(assetKey);
    return decode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        maxWidth: maxWidth);
  }

  /// A mid-grey stand-in so a scene renders (dully) before the real map
  /// decodes, instead of flashing black.
  factory EquirectTexture.flat([int level = 128]) =>
      EquirectTexture(1, 1, Uint8List.fromList([level, level, level, 255]));

  final Float64List _rgba = Float64List(4);

  /// three's `envmap_pars_fragment` mapping for
  /// `EquirectangularReflectionMapping`, given a **world-space** direction:
  ///
  /// ```glsl
  /// sampleUV.y = asin(clamp(dir.y, -1, 1)) * RECIPROCAL_PI + 0.5;
  /// sampleUV.x = atan(dir.z, dir.x) * RECIPROCAL_PI2 + 0.5;
  /// ```
  void sampleDirection(double dx, double dy, double dz, Float64List out) {
    final len = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (len < 1e-12) {
      out[0] = out[1] = out[2] = 0;
      return;
    }
    final ny = dy / len;
    final u = math.atan2(dz / len, dx / len) * (1.0 / (2 * math.pi)) + 0.5;
    final v = math.asin(ny < -1 ? -1 : (ny > 1 ? 1 : ny)) * (1.0 / math.pi) + 0.5;
    sample(u, v, _rgba);
    out[0] = _rgba[0];
    out[1] = _rgba[1];
    out[2] = _rgba[2];
  }
}
