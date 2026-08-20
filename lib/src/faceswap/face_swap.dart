// The per-frame half of the art-painting swap: cut the user's face, recolour
// it to the painting's palette, and hand back an image to draw under the hole.
//
// Port of `draw_render()` and the `FINAL RENDER FACE` shader.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/texture.dart';
import '../core/video_texture.dart';
import '../tracking/detect_state.dart';
import 'art_painting.dart';

/// Cuts the user's face out of a camera frame and recolours it towards a
/// painting's palette.
///
/// Reuses one output buffer across frames, so a 30fps stream does not churn
/// the heap.
class FaceSwapCompositor {
  FaceSwapCompositor({this.settings = const ArtPaintingSettings()});

  final ArtPaintingSettings settings;

  Uint8List? _out;
  Texture2D? _userSignature;

  /// The user's own 4x4 colour signature from the last frame, for debugging.
  Texture2D? get userSignature => _userSignature;

  /// Produces a square RGBA crop of the user's face, already recoloured.
  ///
  /// [video] must carry colour — the swap is entirely about colour, so luma
  /// alone would defeat the point. [mirror] matches the preview.
  Uint8List? cropAndRecolour({
    required VideoLumaTexture video,
    required DetectState state,
    required ArtPainting painting,
    bool mirror = true,
  }) {
    if (!video.hasColor) return null;
    if (state.detected <= 0 || state.s <= 1e-6) return null;

    final n = settings.faceRenderSizePx;
    final out = _out ??= Uint8List(n * n * 4);

    // The user's box uses the same formula as the painting's, but with
    // `zoomFactor` pulling the crop in slightly and no aspect correction —
    // the target is already square.
    final box = FaceBox.fromDetectState(
      state,
      settings,
      zoom: settings.zoomFactor,
    );

    // First pass: cut the face into `out`, and accumulate the user's own
    // colour signature as we go. Doing both in one pass means the video is
    // sampled once rather than twice.
    final sig = settings.hueTextureSizePx;
    final accum = Float64List(sig * sig * 3);
    final counts = Int32List(sig * sig);

    final rgb = Float64List(3);
    final clamped = Float64List(2);
    final rgbClamped = Float64List(3);

    for (var py = 0; py < n; py++) {
      final fv = (py + 0.5) / n;
      for (var px = 0; px < n; px++) {
        final fu = (px + 0.5) / n;

        // Sample the video inside the face box. Two flips to keep straight:
        // the box lives in shader space (v counts up) while both this crop's
        // rows and the video texture count down, so v is converted twice.
        final u = box.xn + (fu - 0.5) * box.sxn;
        final vShader = box.yn + (0.5 - fv) * box.syn;

        var uOut = u;
        if (mirror) uOut = 1.0 - uOut;
        video.sampleRgb(uOut, 1.0 - vShader, rgb);

        final i = (py * n + px) * 4;
        out[i] = (rgb[0] * 255).round().clamp(0, 255);
        out[i + 1] = (rgb[1] * 255).round().clamp(0, 255);
        out[i + 2] = (rgb[2] * 255).round().clamp(0, 255);
        out[i + 3] = 255;

        // The signature is fed by the *border-clamped* sample, per the demo's
        // separate `cropUserFace` pass. Only pixels within 0.8 of the frame
        // centre are unaffected, so this second fetch is rare.
        var sr = rgb[0], sg = rgb[1], sb = rgb[2];
        clampToBorder(u, vShader, clamped);
        if (clamped[0] != u || clamped[1] != vShader) {
          var cu = clamped[0];
          if (mirror) cu = 1.0 - cu;
          video.sampleRgb(cu, 1.0 - clamped[1], rgbClamped);
          sr = rgbClamped[0];
          sg = rgbClamped[1];
          sb = rgbClamped[2];
        }

        final cx = (fu * sig).floor().clamp(0, sig - 1);
        final cy = (fv * sig).floor().clamp(0, sig - 1);
        final ci = cy * sig + cx;
        accum[ci * 3] += sr;
        accum[ci * 3 + 1] += sg;
        accum[ci * 3 + 2] += sb;
        counts[ci]++;
      }
    }

    // Build the user's signature from the accumulator.
    final sigPx = Uint8List(sig * sig * 4);
    for (var i = 0; i < sig * sig; i++) {
      final c = counts[i] == 0 ? 1 : counts[i];
      sigPx[i * 4] = (accum[i * 3] / c * 255).round().clamp(0, 255);
      sigPx[i * 4 + 1] = (accum[i * 3 + 1] / c * 255).round().clamp(0, 255);
      sigPx[i * 4 + 2] = (accum[i * 3 + 2] / c * 255).round().clamp(0, 255);
      sigPx[i * 4 + 3] = 255;
    }
    final userSig = _userSignature = Texture2D(sig, sig, sigPx);

    // Second pass: recolour in place against the two signatures.
    _recolour(out, n, userSig, painting.hueSignature);
    return out;
  }

  /// The `FINAL RENDER FACE` shader's colour transform, per pixel:
  ///
  /// ```glsl
  /// vec2 factorSV = vec2(1., 0.8) * dstHSV.yz / (srcHSV.yz + EPSILON2);
  /// factorSV = clamp(factorSV, vec2(0.3, 0.3), vec2(3., 3.));
  /// float dHue = dstHSV.x - srcHSV.x;
  /// vec3 out = vec3(mod(1.0 + colorHSV.x + dHue, 1.0), colorHSV.yz * factorSV);
  /// ```
  ///
  /// So: shift hue by the local difference, and scale saturation and value by
  /// the local ratio — clamped, because a near-black cell would otherwise send
  /// the ratio to infinity. The 0.8 on value deliberately under-corrects
  /// brightness; a fully matched value looks flat.
  void _recolour(
      Uint8List face, int n, Texture2D src, Texture2D dst) {
    final srcTexel = Float64List(4);
    final dstTexel = Float64List(4);
    final hsv = Float64List(3);
    final srcHsv = Float64List(3);
    final dstHsv = Float64List(3);
    final rgb = Float64List(3);

    const eps = 0.001;

    for (var py = 0; py < n; py++) {
      final v = (py + 0.5) / n;
      for (var px = 0; px < n; px++) {
        final u = (px + 0.5) / n;
        final i = (py * n + px) * 4;

        rgbToHsv(face[i] / 255, face[i + 1] / 255, face[i + 2] / 255, hsv);

        src.sampleTopDown(u, v, srcTexel);
        dst.sampleTopDown(u, v, dstTexel);
        rgbToHsv(srcTexel[0], srcTexel[1], srcTexel[2], srcHsv);
        rgbToHsv(dstTexel[0], dstTexel[1], dstTexel[2], dstHsv);

        final fs = (dstHsv[1] / (srcHsv[1] + eps)).clamp(0.3, 3.0);
        final fv = (0.8 * dstHsv[2] / (srcHsv[2] + eps)).clamp(0.3, 3.0);
        final dHue = dstHsv[0] - srcHsv[0];

        final h = (1.0 + hsv[0] + dHue) % 1.0;
        final s = (hsv[1] * fs).clamp(0.0, 1.0);
        final val = (hsv[2] * fv).clamp(0.0, 1.0);

        hsvToRgb(h, s, val, rgb);
        face[i] = (rgb[0] * 255).round().clamp(0, 255);
        face[i + 1] = (rgb[1] * 255).round().clamp(0, 255);
        face[i + 2] = (rgb[2] * 255).round().clamp(0, 255);
      }
    }
  }

  /// Turns the last crop into an image. Async because that is the only route
  /// from bytes to `ui.Image`.
  Future<ui.Image> toImage(Uint8List rgba) async {
    final n = settings.faceRenderSizePx;
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: n, height: n, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    return frame.image;
  }
}

/// `rgb2hsv` from the shader (lolengine's branchless version). Writes h, s, v
/// into [out], all 0..1.
void rgbToHsv(double r, double g, double b, Float64List out) {
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final d = maxC - minC;

  var h = 0.0;
  if (d > 1e-10) {
    if (maxC == r) {
      h = ((g - b) / d) % 6.0;
    } else if (maxC == g) {
      h = (b - r) / d + 2.0;
    } else {
      h = (r - g) / d + 4.0;
    }
    h /= 6.0;
    if (h < 0) h += 1.0;
  }

  out[0] = h;
  out[1] = maxC <= 1e-10 ? 0.0 : d / maxC;
  out[2] = maxC;
}

/// `hsv2rgb` from the shader.
void hsvToRgb(double h, double s, double v, Float64List out) {
  if (s <= 1e-10) {
    out[0] = out[1] = out[2] = v;
    return;
  }
  final hh = (h % 1.0) * 6.0;
  final i = hh.floor();
  final f = hh - i;
  final p = v * (1 - s);
  final q = v * (1 - s * f);
  final t = v * (1 - s * (1 - f));

  switch (i % 6) {
    case 0:
      out[0] = v;
      out[1] = t;
      out[2] = p;
    case 1:
      out[0] = q;
      out[1] = v;
      out[2] = p;
    case 2:
      out[0] = p;
      out[1] = v;
      out[2] = t;
    case 3:
      out[0] = p;
      out[1] = q;
      out[2] = v;
    case 4:
      out[0] = t;
      out[1] = p;
      out[2] = v;
    default:
      out[0] = v;
      out[1] = p;
      out[2] = q;
  }
}
