// The camera frame, as something a fragment shader can sample.
//
// The tiger's mask shader reads the video and mixes it with the mask:
//
// ```glsl
// vec4 videoColor = texture2D(samplerVideo, uvVideo);
// float videoColorGS = dot(vec3(0.299, 0.587, 0.114), videoColor.rgb);
// videoColor.rgb = videoColorGS * vec3(1.5, 0.6, 0.0);
// gl_FragColor = mix(videoColor, gl_FragColor, alphaMask);
// ```
//
// It throws the colour away immediately and keeps only the BT.601 luma. That is
// a large piece of luck: NV21 — what the Android camera hands us — stores
// exactly that luma as its first plane, full resolution, one byte per pixel, no
// conversion needed. For the tiger the whole thing costs a strided copy.
//
// Without it the eye region of the tiger renders black: `mix(videoColor, …, 0)`
// is *videoColor*, so the "see-through" parts are not transparent at all —
// they are the video, drawn by the mask, tinted orange.
//
// rupy_helmet then raised the bar: its face mask uses `videoColor.rgb` as
// actual colour, so RGB is available too, opt-in, via NV21's half-resolution
// interleaved chroma.

import 'dart:typed_data';

/// Rotation needed to bring a camera buffer upright, in degrees clockwise.
enum VideoRotation { none, cw90, cw180, cw270 }

VideoRotation videoRotationFromDegrees(int degrees) {
  switch (((degrees % 360) + 360) % 360) {
    case 90:
      return VideoRotation.cw90;
    case 180:
      return VideoRotation.cw180;
    case 270:
      return VideoRotation.cw270;
    default:
      return VideoRotation.none;
  }
}

/// A small, upright copy of the camera frame.
///
/// Always carries luma. Also carries RGB when the filter asked for it —
/// rupy_helmet's face mask uses `texture2D(samplerVideo, …).rgb` directly,
/// where the tiger only ever wanted the grayscale. Colour costs a YUV->RGB
/// conversion, so it is opt-in.
class VideoLumaTexture {
  VideoLumaTexture(this.width, this.height, {bool color = false})
      : luma = Uint8List(width * height),
        rgb = color ? Uint8List(width * height * 3) : null;

  final int width, height;

  /// Row-major from the **top**, one byte per pixel.
  final Uint8List luma;

  /// Row-major from the top, three bytes per pixel. Null unless colour was
  /// requested.
  final Uint8List? rgb;

  bool get hasColor => rgb != null;

  /// Bilinear RGB fetch, 0..1, [u]/[v] from the top-left. Writes into
  /// [out][0..2]. Falls back to grey from [luma] when colour is absent, so a
  /// filter still renders (monochrome) rather than black.
  void sampleRgb(double u, double v, Float64List out) {
    final c = rgb;
    if (c == null) {
      final g = sample(u, v);
      out[0] = g;
      out[1] = g;
      out[2] = g;
      return;
    }

    var x = (u < 0 ? 0.0 : (u > 1 ? 1.0 : u)) * width - 0.5;
    var y = (v < 0 ? 0.0 : (v > 1 ? 1.0 : v)) * height - 0.5;
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    final x0f = x.floorToDouble(), y0f = y.floorToDouble();
    final fx = x - x0f, fy = y - y0f;

    var x0 = x0f.toInt(), y0 = y0f.toInt();
    if (x0 > width - 1) x0 = width - 1;
    if (y0 > height - 1) y0 = height - 1;
    final x1 = x0 + 1 > width - 1 ? width - 1 : x0 + 1;
    final y1 = y0 + 1 > height - 1 ? height - 1 : y0 + 1;

    final i00 = (y0 * width + x0) * 3;
    final i10 = (y0 * width + x1) * 3;
    final i01 = (y1 * width + x0) * 3;
    final i11 = (y1 * width + x1) * 3;

    const inv = 1.0 / 255.0;
    for (var k = 0; k < 3; k++) {
      final top = c[i00 + k] + (c[i10 + k] - c[i00 + k]) * fx;
      final bot = c[i01 + k] + (c[i11 + k] - c[i01 + k]) * fx;
      out[k] = (top + (bot - top) * fy) * inv;
    }
  }

  /// Bilinear fetch, 0..1, with [u]/[v] measured from the top-left — matching
  /// [Fragment.vpU]/[Fragment.vpV].
  double sample(double u, double v) {
    var x = (u < 0 ? 0.0 : (u > 1 ? 1.0 : u)) * width - 0.5;
    var y = (v < 0 ? 0.0 : (v > 1 ? 1.0 : v)) * height - 0.5;
    if (x < 0) x = 0;
    if (y < 0) y = 0;

    final x0f = x.floorToDouble(), y0f = y.floorToDouble();
    final fx = x - x0f, fy = y - y0f;

    var x0 = x0f.toInt(), y0 = y0f.toInt();
    if (x0 > width - 1) x0 = width - 1;
    if (y0 > height - 1) y0 = height - 1;
    final x1 = x0 + 1 > width - 1 ? width - 1 : x0 + 1;
    final y1 = y0 + 1 > height - 1 ? height - 1 : y0 + 1;

    final r0 = y0 * width, r1 = y1 * width;
    final v00 = luma[r0 + x0].toDouble(), v10 = luma[r0 + x1].toDouble();
    final v01 = luma[r1 + x0].toDouble(), v11 = luma[r1 + x1].toDouble();

    final top = v00 + (v10 - v00) * fx;
    final bot = v01 + (v11 - v01) * fx;
    return (top + (bot - top) * fy) * (1.0 / 255.0);
  }
}

/// Builds an upright, downsampled luma texture from a camera frame.
///
/// Reused across frames: the output buffer is allocated once for a given
/// target size and overwritten in place, so a 30fps stream does not churn the
/// heap.
class VideoLumaSampler {
  VideoLumaSampler({this.maxDimension = 192, this.color = false});

  /// Whether to also produce RGB. Costs a YUV->RGB conversion per output
  /// pixel, which at 192px is a fraction of a millisecond — but there is no
  /// reason to pay it for a filter that only reads luma.
  final bool color;

  /// Longest side of the produced texture.
  ///
  /// Both filters that read the video use it softly — a displaced wash around
  /// the tiger's eyes, a darkened fill under the helmet — so it needs far less
  /// resolution than the camera provides. 192 keeps the copy down to ~35k
  /// samples per frame.
  final int maxDimension;

  VideoLumaTexture? _texture;

  VideoLumaTexture? get texture => _texture;

  /// Consumes an NV21/YUV420 buffer.
  ///
  /// [plane] may be just the Y plane, or — when [color] is set — the full NV21
  /// buffer, whose interleaved VU chroma follows Y at offset
  /// `rowStride * srcHeight`. NV21 stores chroma at half resolution in both
  /// axes, V before U.
  ///
  /// [rowStride] is the source row pitch in bytes, which is not always equal
  /// to [srcWidth] — Android pads rows for alignment, and ignoring that shears
  /// the image.
  VideoLumaTexture fromLumaPlane(
    Uint8List plane,
    int srcWidth,
    int srcHeight, {
    required int rowStride,
    VideoRotation rotation = VideoRotation.none,
  }) {
    final swap =
        rotation == VideoRotation.cw90 || rotation == VideoRotation.cw270;
    final uprightW = swap ? srcHeight : srcWidth;
    final uprightH = swap ? srcWidth : srcHeight;

    final tex = _target(uprightW, uprightH);
    final dw = tex.width, dh = tex.height;
    final dst = tex.luma;
    final rgbOut = tex.rgb;
    final chromaOffset = rowStride * srcHeight;

    for (var dy = 0; dy < dh; dy++) {
      // Sample at pixel centres so the downsample does not bias up-left.
      final uy = ((dy + 0.5) * uprightH / dh).floor().clamp(0, uprightH - 1);
      final rowOut = dy * dw;

      for (var dx = 0; dx < dw; dx++) {
        final ux = ((dx + 0.5) * uprightW / dw).floor().clamp(0, uprightW - 1);

        // Map upright coords back into the unrotated source.
        int sx, sy;
        switch (rotation) {
          case VideoRotation.none:
            sx = ux;
            sy = uy;
          case VideoRotation.cw90:
            // Upright (ux, uy) came from source (uy, srcHeight-1-ux).
            sx = uy;
            sy = srcHeight - 1 - ux;
          case VideoRotation.cw180:
            sx = srcWidth - 1 - ux;
            sy = srcHeight - 1 - uy;
          case VideoRotation.cw270:
            sx = srcWidth - 1 - uy;
            sy = ux;
        }

        final si = sy * rowStride + sx;
        final yv = si >= 0 && si < plane.length ? plane[si] : 0;
        dst[rowOut + dx] = yv;

        if (rgbOut != null) {
          // NV21: interleaved V,U at half resolution, after the Y plane.
          final cRow = sy >> 1, cCol = sx >> 1;
          final ci = chromaOffset + cRow * rowStride + cCol * 2;
          var u = 128, v = 128;
          if (ci >= 0 && ci + 1 < plane.length) {
            v = plane[ci];
            u = plane[ci + 1];
          }
          _yuvToRgb(yv, u, v, rgbOut, (rowOut + dx) * 3);
        }
      }
    }

    return tex;
  }

  /// BT.601 full-range YUV -> RGB, the inverse of the luma weights used above.
  static void _yuvToRgb(int y, int u, int v, Uint8List out, int at) {
    final du = u - 128, dv = v - 128;
    final r = y + 1.402 * dv;
    final g = y - 0.344136 * du - 0.714136 * dv;
    final b = y + 1.772 * du;
    out[at] = r < 0 ? 0 : (r > 255 ? 255 : r.round());
    out[at + 1] = g < 0 ? 0 : (g > 255 ? 255 : g.round());
    out[at + 2] = b < 0 ? 0 : (b > 255 ? 255 : b.round());
  }

  /// Consumes an interleaved 8888 buffer, taking BT.601 luma per pixel.
  /// [bgra] selects the channel order (iOS gives BGRA, most else RGBA).
  VideoLumaTexture fromInterleaved8888(
    Uint8List pixels,
    int srcWidth,
    int srcHeight, {
    required int rowStride,
    bool bgra = true,
    VideoRotation rotation = VideoRotation.none,
  }) {
    final swap =
        rotation == VideoRotation.cw90 || rotation == VideoRotation.cw270;
    final uprightW = swap ? srcHeight : srcWidth;
    final uprightH = swap ? srcWidth : srcHeight;

    final tex = _target(uprightW, uprightH);
    final dw = tex.width, dh = tex.height;
    final dst = tex.luma;
    final rgbOut = tex.rgb;
    final rIdx = bgra ? 2 : 0, bIdx = bgra ? 0 : 2;

    for (var dy = 0; dy < dh; dy++) {
      final uy = ((dy + 0.5) * uprightH / dh).floor().clamp(0, uprightH - 1);
      final rowOut = dy * dw;

      for (var dx = 0; dx < dw; dx++) {
        final ux = ((dx + 0.5) * uprightW / dw).floor().clamp(0, uprightW - 1);

        int sx, sy;
        switch (rotation) {
          case VideoRotation.none:
            sx = ux;
            sy = uy;
          case VideoRotation.cw90:
            sx = uy;
            sy = srcHeight - 1 - ux;
          case VideoRotation.cw180:
            sx = srcWidth - 1 - ux;
            sy = srcHeight - 1 - uy;
          case VideoRotation.cw270:
            sx = srcWidth - 1 - uy;
            sy = ux;
        }

        final si = sy * rowStride + sx * 4;
        if (si < 0 || si + 3 >= pixels.length) {
          dst[rowOut + dx] = 0;
          if (rgbOut != null) {
            final o = (rowOut + dx) * 3;
            rgbOut[o] = 0;
            rgbOut[o + 1] = 0;
            rgbOut[o + 2] = 0;
          }
          continue;
        }
        final r = pixels[si + rIdx], g = pixels[si + 1], b = pixels[si + bIdx];
        dst[rowOut + dx] =
            (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
        if (rgbOut != null) {
          final o = (rowOut + dx) * 3;
          rgbOut[o] = r;
          rgbOut[o + 1] = g;
          rgbOut[o + 2] = b;
        }
      }
    }

    return tex;
  }

  VideoLumaTexture _target(int uprightW, int uprightH) {
    final aspect = uprightW / uprightH;
    int w, h;
    if (aspect >= 1) {
      w = maxDimension;
      h = (maxDimension / aspect).round();
    } else {
      h = maxDimension;
      w = (maxDimension * aspect).round();
    }
    if (w < 2) w = 2;
    if (h < 2) h = 2;

    final existing = _texture;
    if (existing != null &&
        existing.width == w &&
        existing.height == h &&
        existing.hasColor == color) {
      return existing;
    }
    return _texture = VideoLumaTexture(w, h, color: color);
  }
}
