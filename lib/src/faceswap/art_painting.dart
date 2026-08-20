// Port of demos/faceReplacement/image — your face inside a painting or poster.
//
// A third kind of thing again. glassesVTO..multiLiberty render a 3D scene;
// comedy-glasses transforms a widget; this one is 2D image compositing, and
// touches neither the rasteriser nor the scene graph.
//
// How the original works, in order:
//
//  1. Find where the *painting's* face is, by running the face detector on the
//     painting itself. That gives a `DetectState` just like a camera frame
//     would. (The demo hard-codes the answer for the Mona Lisa to skip the
//     wait; anything else it searches for.)
//  2. From that, compute one face box — `xn, yn, sxn, syn` — and cut a
//     soft-edged **hole** in the painting over it. The hole is head-shaped:
//     a circular arc for the forehead, another for the jaw, straight sides in
//     between, and then modulated by luminance so dark hair blends differently
//     from lit skin.
//  3. Reduce the painting's cut-out face to a 4x4 "hue signature".
//  4. Per camera frame, cut the user's face with the *same* box formula, reduce
//     it to its own 4x4 signature, and shift its HSV towards the painting's —
//     so the face arrives already colour-matched to the artwork.
//  5. Draw the user's face, then the holed painting on top of it.
//
// Step 4 is what makes it convincing. Without it you get a photograph pasted
// into an oil painting; with it, a face that shares the painting's palette.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/texture.dart';
import '../tracking/detect_state.dart';

/// `SETTINGS` from the demo's main.js, minus the parts about its search UI.
class ArtPaintingSettings {
  const ArtPaintingSettings({
    this.maskScale = const [1.3, 1.5],
    this.maskOffset = const [-0.2, 0.1],
    this.cropSmoothEdge = 0.25,
    this.headForeheadY = 0.7,
    this.headJawY = 0.5,
    this.faceRenderSizePx = 256,
    this.hueTextureSizePx = 4,
    this.zoomFactor = 1.03,
  });

  /// Size of the face box relative to the detection window.
  final List<double> maskScale;

  /// Offset of the box. X is multiplied by `sin(ry)` so the hole tracks a
  /// painting whose sitter is turned slightly, which most portraits are.
  final List<double> maskOffset;

  /// Width of the soft edge on the hole, in box-relative units.
  final double cropSmoothEdge;

  /// Where the forehead arc starts and the jaw arc ends, as a fraction up the
  /// box. Between them the sides are straight.
  final double headForeheadY;
  final double headJawY;

  /// Resolution the user's face is cut to.
  final int faceRenderSizePx;

  /// Side of the square colour signature. Four means sixteen colour samples —
  /// enough to carry a palette, too coarse to carry any detail.
  final int hueTextureSizePx;

  /// 1.0 would crop the user exactly as tightly as the painting. Slightly
  /// above pulls the user's face in a little so its edges land inside the hole.
  final double zoomFactor;
}

/// Where a face sits inside an image, in normalised 0..1 coordinates.
///
/// `xn, yn` is the centre and `sxn, syn` the full width and height, which is
/// the form both the mask builder and the crop want.
class FaceBox {
  const FaceBox(this.xn, this.yn, this.sxn, this.syn);

  final double xn, yn, sxn, syn;

  double get left => xn - sxn / 2;

  /// Top edge in shader space, where v counts up.
  double get top => yn - syn / 2;

  /// Top edge with v counting down, which is what a canvas wants.
  ///
  /// `position_userCropCanvas()` does exactly this flip:
  /// `topPx = imageHeight - imageHeight*positionFace[1]`, then subtracts half
  /// the face height to go from centre to corner.
  double get topFlipped => 1.0 - yn - syn / 2;

  /// The box as a pixel rectangle in an [w] x [h] image, v counting down.
  ui.Rect rectIn(int w, int h) =>
      ui.Rect.fromLTWH(left * w, topFlipped * h, sxn * w, syn * h);

  @override
  String toString() => 'FaceBox(x=${xn.toStringAsFixed(4)}, '
      'y=${yn.toStringAsFixed(4)}, w=${sxn.toStringAsFixed(4)}, '
      'h=${syn.toStringAsFixed(4)})';

  /// The demo's box formula, shared by the painting and the user:
  ///
  /// ```js
  /// xn = x*0.5 + 0.5 + s*maskOffset[0]*Math.sin(ry);
  /// yn = y*0.5 + 0.5 + s*maskOffset[1];
  /// sxn = s * maskScale[0];
  /// syn = s * maskScale[1];
  /// ```
  ///
  /// [aspect] is the image's width/height, applied to the height only. The
  /// painting side passes it (so the box stays square in pixels on a
  /// non-square canvas); the user side passes 1, because its crop target is
  /// already square.
  static FaceBox fromDetectState(
    DetectState state,
    ArtPaintingSettings settings, {
    double aspect = 1.0,
    double zoom = 1.0,
  }) {
    final s = state.s / zoom;
    return FaceBox(
      state.x * 0.5 + 0.5 + s * settings.maskOffset[0] * math.sin(state.ry),
      state.y * 0.5 + 0.5 + s * settings.maskOffset[1],
      s * settings.maskScale[0],
      s * settings.maskScale[1] * aspect,
    );
  }
}

/// A painting with a head-shaped hole cut in it, plus the colour signature of
/// the face that used to be there.
class ArtPainting {
  ArtPainting({
    required this.image,
    required this.box,
    required this.hueSignature,
    required this.width,
    required this.height,
  });

  /// The painting with the face cut out, ready to draw *over* the user's face.
  final ui.Image image;

  /// Where the hole is.
  final FaceBox box;

  /// The 4x4 (by default) colour signature of the painting's own face.
  final Texture2D hueSignature;

  final int width, height;

  void dispose() => image.dispose();
}

/// Builds the holed painting and its colour signature.
///
/// This runs once per painting, not per frame.
Future<ArtPainting> buildArtPainting({
  required Uint8List encodedImage,
  required DetectState paintingFace,
  ArtPaintingSettings settings = const ArtPaintingSettings(),
  int? maxWidth,
}) async {
  final source = await Texture2D.decode(encodedImage, maxWidth: maxWidth);
  final w = source.width, h = source.height;

  final box = FaceBox.fromDetectState(
    paintingFace,
    settings,
    aspect: w / h,
  );

  final holed = cutFaceHole(source, box, settings);
  final signature = hueSignature(source, box, settings);

  final image = await _decodeRgba(holed, w, h);
  return ArtPainting(
    image: image,
    box: box,
    hueSignature: signature,
    width: w,
    height: h,
  );
}

/// Port of the `BUILD ARTPAINTING MASK` fragment shader.
///
/// Returns premultiplied RGBA: opaque everywhere except a head-shaped, soft
/// hole over [box].
Uint8List cutFaceHole(
    Texture2D source, FaceBox box, ArtPaintingSettings settings) {
  final w = source.width, h = source.height;
  final out = Uint8List(w * h * 4);
  final texel = Float64List(4);

  final sx2 = box.sxn / 2, sy2 = box.syn / 2;
  final upper = settings.headForeheadY;
  final lower = settings.headJawY;
  final smooth = settings.cropSmoothEdge;

  for (var py = 0; py < h; py++) {
    // The shader's vUV counts from the bottom; a raster row counts from the
    // top. Everything below is in shader space, then written to the right row.
    final v = 1.0 - (py + 0.5) / h;
    final rowOut = py * w * 4;

    for (var px = 0; px < w; px++) {
      final u = (px + 0.5) / w;
      source.sampleTopDown(u, (py + 0.5) / h, texel);

      final i = rowOut + px * 4;

      // `step(vUV, offset+s2) * step(offset-s2, vUV)` — outside the box the
      // painting is left completely alone.
      final inBox = u >= box.xn - sx2 &&
          u <= box.xn + sx2 &&
          v >= box.yn - sy2 &&
          v <= box.yn + sy2;
      if (!inBox) {
        out[i] = (texel[0] * 255).round().clamp(0, 255);
        out[i + 1] = (texel[1] * 255).round().clamp(0, 255);
        out[i + 2] = (texel[2] * 255).round().clamp(0, 255);
        out[i + 3] = 255;
        continue;
      }

      // uv normalised inside the face box.
      final fu = (u - box.xn + sx2) / (2 * sx2);
      final fv = (v - box.yn + sy2) / (2 * sy2);

      double alpha;
      if (fv > upper) {
        // Upper head: a circular arc, blended with a plain vertical fade
        // towards the middle so the top of the skull does not get a hard rim.
        final cx = fu - 0.5;
        final cy = (fv - upper) * (0.5 / (1.0 - upper));
        final alphaBorder =
            _smoothstep(0.5 - smooth, 0.5, math.sqrt(cx * cx + cy * cy));
        final alphaCenter = _smoothstep(upper, 1.0, fv);
        alpha = _mix(
            alphaCenter, alphaBorder, _smoothstep(0.3, 0.4, (fu - 0.5).abs()));
      } else if (fv < lower) {
        // Lower head: a circular arc for the jaw.
        final cx = fu - 0.5;
        final cy = (fv - lower) * (0.5 / lower);
        alpha = _smoothstep(0.5 - smooth, 0.5, math.sqrt(cx * cx + cy * cy));
      } else {
        // Middle: straight sides.
        alpha = _smoothstep(0.5 - smooth, 0.5, (fu - 0.5).abs());
      }

      // Luminance modulation: dark regions (hair, shadow) keep more of the
      // painting, lit regions give way to the user's face sooner.
      final gray = (texel[0] + texel[1] + texel[2]) * 0.33;
      if (alpha > 0.01) {
        alpha = _mix(math.pow(alpha, 0.5).toDouble(),
            math.pow(alpha, 1.5).toDouble(), _smoothstep(0.1, 0.5, gray));
      }
      alpha = alpha.clamp(0.0, 1.0);

      // The shader emits `vec4(color, alpha)` and the draw runs under
      // `blendFunc(SRC_ALPHA, ZERO)`, which multiplies *every* channel by the
      // source alpha — so the framebuffer ends up with `color*alpha` and
      // `alpha*alpha`. Against a premultiplied canvas that makes the hole fade
      // on alpha squared while the colour fades on alpha. Almost certainly not
      // deliberate — blendFunc was reached for to overwrite, not to blend — but
      // it is what the demo looks like, and the squared falloff is the wider,
      // softer edge that makes the seam work.
      final a2 = alpha * alpha;
      out[i] = (texel[0] * alpha * 255).round().clamp(0, 255);
      out[i + 1] = (texel[1] * alpha * 255).round().clamp(0, 255);
      out[i + 2] = (texel[2] * alpha * 255).round().clamp(0, 255);
      out[i + 3] = (a2 * 255).round().clamp(0, 255);
    }
  }
  return out;
}

/// The 4x4 colour signature of whatever is inside [box].
///
/// The original renders the face crop to a power-of-two texture, generates
/// mipmaps and samples the small level — which is a box filter. This averages
/// directly, which is the same thing without the round trip.
///
/// It does *not* reproduce the demo's `copyInvX` step. That flip exists only
/// to cancel the `uv = vec2(1.-vUV.x, vUV.y)` in the final shader, which
/// samples both signatures mirrored. Here the signature is sampled at the
/// output pixel's own u, so painting cell 0 must stay the painting's left —
/// flipping it as well would swap the palette across the face. [flipX] is kept
/// so a test can demonstrate the difference.
Texture2D hueSignature(
  Texture2D source,
  FaceBox box,
  ArtPaintingSettings settings, {
  bool flipX = false,
}) {
  final n = settings.hueTextureSizePx;
  final px = Uint8List(n * n * 4);
  final texel = Float64List(4);
  final clamped = Float64List(2);

  // How many source samples to average per cell. Enough to be a real average,
  // cheap enough to not matter — this runs once per painting.
  const samples = 8;

  for (var cy = 0; cy < n; cy++) {
    for (var cx = 0; cx < n; cx++) {
      var r = 0.0, g = 0.0, b = 0.0;

      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final fu = (cx + (sx + 0.5) / samples) / n;
          final fv = (cy + (sy + 0.5) / samples) / n;

          final u = box.xn + (fu - 0.5) * box.sxn;
          // Cell rows count downward; the box's v counts upward.
          final vShader = box.yn + (0.5 - fv) * box.syn;

          clampToBorder(u, vShader, clamped);
          source.sampleTopDown(clamped[0], 1.0 - clamped[1], texel);
          r += texel[0];
          g += texel[1];
          b += texel[2];
        }
      }

      const inv = 1.0 / (samples * samples);
      final outX = flipX ? (n - 1 - cx) : cx;
      final i = (cy * n + outX) * 4;
      px[i] = (r * inv * 255).round().clamp(0, 255);
      px[i + 1] = (g * inv * 255).round().clamp(0, 255);
      px[i + 2] = (b * inv * 255).round().clamp(0, 255);
      px[i + 3] = 255;
    }
  }

  return Texture2D(n, n, px);
}

/// The `CUT ARTPAINTING FACE` fragment shader's radial clamp:
///
/// ```glsl
/// const float BORDER = 0.2;
/// vec2 uvCentered = 2.0 * vUV - vec2(1., 1.);
/// float ruv = length(uvCentered);
/// vec2 uvBorder = (uvCentered / ruv) * (1. - BORDER);
/// uvCentered = mix(uvCentered, uvBorder, step(1. - BORDER, ruv));
/// ```
///
/// Any sample further than 0.8 from the image centre is pulled back onto that
/// circle. It keeps a face near the edge of frame from dragging the border
/// pixels — and whatever is outside them — into the colour signature. It
/// applies to the signature crop only; the displayed face is sampled straight.
///
/// Writes the clamped (u, v) into [out], both in shader space.
void clampToBorder(double u, double v, Float64List out) {
  const border = 0.2;
  final cu = 2.0 * u - 1.0, cv = 2.0 * v - 1.0;
  final r = math.sqrt(cu * cu + cv * cv);
  if (r <= 1.0 - border || r < 1e-9) {
    out[0] = u;
    out[1] = v;
    return;
  }
  final k = (1.0 - border) / r;
  out[0] = 0.5 + 0.5 * cu * k;
  out[1] = 0.5 + 0.5 * cv * k;
}

double _smoothstep(double e0, double e1, double x) {
  if (e1 == e0) return x < e0 ? 0 : 1;
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _mix(double a, double b, double t) => a + (b - a) * t;

Future<ui.Image> _decodeRgba(Uint8List rgba, int w, int h) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer,
      width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  return frame.image;
}
