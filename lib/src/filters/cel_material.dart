// Port of demos/threejs/celFace/shaders/celFragmentShader.gl.
//
// The shader's own header credits geeks3d's "toonify" post-processing filter.
// It is a *screen-space* effect wearing a mesh: nothing about the geometry
// reaches the colour except the silhouette. Each fragment samples the camera at
// its own projected screen position, posterises that colour in HSV, and paints
// it black if a 3x3 intensity operator says it sits on an edge. The low-poly
// head is there purely to say *where* — it is a stencil, not a surface.
//
// Two consequences worth stating up front, because they explain what the filter
// looks like:
//
//  * The mesh's normals are computed by the demo (`computeVertexNormals()`) and
//    then never read. No lighting, no shading, no view dependence.
//  * Most of the colour work is laundered away downstream. celFace's final
//    composite reduces this material's output to luma and re-tints it ivory, so
//    the hue and saturation quantisation only reach the screen through their
//    effect on *brightness*. The 3-level value quantisation is what actually
//    posterises; the black edges are what actually read as ink.

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/material.dart';
import '../core/video_texture.dart';

class CelFaceMaterial extends Material {
  CelFaceMaterial({this.video, this.mirrorVideo = false});

  /// Camera frame. Null until the first one arrives.
  VideoLumaTexture? video;

  /// Must match the overlay's mirroring, or the toon face samples the wrong
  /// side of the head.
  bool mirrorVideo;

  /// `const float EDGE_THRESHOLD = 0.2;` — above this the fragment goes black.
  static const double kEdgeThreshold = 0.2;

  /// `const float EDGE_THRESHOLD2 = 5.0;` — gain on the intensity difference
  /// before the threshold is applied.
  static const double kEdgeGain = 5.0;

  /// `const vec3 THIRD3 = vec3(0.333, 0.333, 0.333);`
  ///
  /// Note this is 0.999, not 1 — the original's edge detector runs on an
  /// intensity that is a thousandth low. It cancels out of a difference, so it
  /// changes nothing, but the constant is kept as written.
  static const double kThird = 0.333;

  /// The shader writes `gl_FragColor.a = 1.0` and three's default
  /// `transparent: false` keeps the pass opaque. The alpha channel of the
  /// render target is what the blur passes then work on.
  @override
  bool get transparent => false;

  /// The shader reads no normal — the demo computes them and then ignores them
  /// — so the renderer can skip building a normal matrix for this mesh.
  @override
  bool get needsNormals => false;

  final Float64List _rgb = Float64List(3);
  final Float64List _hsv = Float64List(3);
  final Float64List _out = Float64List(3);
  final Float64List _tap = Float64List(3);

  @override
  bool shade(Fragment f, Float64List out) {
    final vid = video;
    if (vid == null) {
      // No camera yet: still claim the silhouette so the blur passes have
      // something to shape, but paint it black rather than leaving it
      // uninitialised.
      out[0] = out[1] = out[2] = 0;
      out[3] = 1;
      return true;
    }

    // `vUVvideo` in the original is computed per vertex from the projected
    // position and interpolated. The fragment's own screen position is both
    // simpler and closer to the intent — sample the video *at this pixel* —
    // and it is what HelmetFaceMaterial already does for the same construct.
    var u = f.vpU;
    if (mirrorVideo) u = 1.0 - u;
    final v = f.vpV;

    vid.sampleRgb(u, v, _rgb);

    rgbToHsvDegrees(_rgb[0], _rgb[1], _rgb[2], _hsv);
    _hsv[0] = nearestHueLevel(_hsv[0]);
    _hsv[1] = nearestSaturationLevel(_hsv[1]);
    _hsv[2] = nearestValueLevel(_hsv[2]);

    final edge = edgeAt(vid, u, v, mirrorVideo, _tap);
    if (edge >= kEdgeThreshold) {
      out[0] = out[1] = out[2] = 0;
    } else {
      hsvDegreesToRgb(_hsv[0], _hsv[1], _hsv[2], _out);
      out[0] = _out[0];
      out[1] = _out[1];
      out[2] = _out[2];
    }
    out[3] = 1;
    return true;
  }

  /// `IsEdge()` — the mean of two axis-aligned and two diagonal intensity
  /// differences across a 3x3 neighbourhood, scaled and clamped.
  ///
  /// The original's step is `1.0 / videoSize`, where `videoSize` is the
  /// *canvas* size — and in the demo the canvas is sized to the video, so the
  /// neighbourhood is one video pixel across. Here the video texture is its own
  /// (smaller) size, so its own texel is used: that keeps the operator's reach
  /// tied to the image it reads, instead of drifting with the render slider.
  static double edgeAt(VideoLumaTexture vid, double u, double v, bool mirror,
      Float64List scratch) {
    final dx = 1.0 / vid.width;
    final dy = 1.0 / vid.height;

    // The mirror flips which neighbour is which, but the operator is symmetric
    // in x — `abs(pix1 - pix7)` and the two diagonals all swap into each other
    // — so it needs no special handling.
    double intensity(double du, double dv) {
      vid.sampleRgb(u + du, v + dv, scratch);
      return (scratch[0] + scratch[1] + scratch[2]) * kThird;
    }

    final p0 = intensity(-dx, -dy);
    final p1 = intensity(-dx, 0);
    final p2 = intensity(-dx, dy);
    final p3 = intensity(0, -dy);
    final p5 = intensity(0, dy);
    final p6 = intensity(dx, -dy);
    final p7 = intensity(dx, 0);
    final p8 = intensity(dx, dy);

    // pix4, the centre, is read by the original and never used.
    final delta = ((p1 - p7).abs() +
            (p5 - p3).abs() +
            (p0 - p8).abs() +
            (p2 - p6).abs()) /
        4.0;

    final e = kEdgeGain * delta;
    return e < 0 ? 0 : (e > 1 ? 1 : e);
  }
}

/// `RGBtoHSV()` from the shader. Hue in **degrees**, 0..360; s and v in 0..1.
///
/// Not the same routine as the face-swap's `rgbToHsv`: that one is the
/// branchless lolengine version normalised to 0..1, this one is the classic
/// Foley/van Dam form and the quantisers below are written against its degrees.
/// Kept separate rather than converted, because the levels are the interesting
/// part and they only make sense in these units.
void rgbToHsvDegrees(double r, double g, double b, Float64List out) {
  final minV = math.min(r, math.min(g, b));
  final maxV = math.max(r, math.max(g, b));
  out[2] = maxV;

  final delta = maxV - minV;
  if (maxV != 0.0) {
    out[1] = delta / maxV;
  } else {
    // The original returns early here with hue -1, saturation 0, value 0.
    // Those then go through the quantisers, which round *every* input up:
    // -1 -> hue 140, 0 -> saturation 0.15, 0 -> value 0.3. So black does not
    // stay black — it comes back as a dark greenish grey at 30% value. That is
    // the filter's black floor, and the only true black in the output is the
    // edge, which is written after the HSV path rather than through it.
    out[1] = 0.0;
    out[0] = -1.0;
    return;
  }

  if (delta == 0.0) {
    // Grey: hue is undefined and the original divides by zero. GLSL yields
    // NaN, and every `<=` against NaN is false, so `nearestLevel0` falls
    // through to 360. The hue does reach the output, because saturation is 0
    // here and `nearestLevel1` rounds that up to 0.15 rather than leaving it
    // achromatic — so grey picks up a faint magenta cast.
    out[0] = 360.0;
    return;
  }

  double h;
  if (r == maxV) {
    h = (g - b) / delta;
  } else if (g == maxV) {
    h = 2.0 + (b - r) / delta;
  } else {
    h = 4.0 + (r - g) / delta;
  }
  h *= 60.0;
  if (h < 0.0) h += 360.0;
  out[0] = h;
}

/// `HSVtoRGB()` from the shader.
///
/// One quirk is deliberately preserved. `nearestLevel0` can return exactly 360,
/// which gives `h/60 == 6` and `i == 6` — a sector the original's chain of
/// `if (i==0..4)` does not name, so it falls through to the final
/// `return vec3(v, p, q)`, the i==5 sector. Hue 360 should be red; it comes out
/// **magenta**. On a face that band catches lips and anything strongly pink,
/// which is exactly where it is most visible. It survives here for the same
/// reason as everything else: this is what the demo looks like.
void hsvDegreesToRgb(double h, double s, double v, Float64List out) {
  if (s == 0.0) {
    out[0] = out[1] = out[2] = v;
    return;
  }

  final hh = h / 60.0;
  final i = hh.floor();
  final f = hh - i;
  final p = v * (1.0 - s);
  final q = v * (1.0 - s * f);
  final t = v * (1.0 - s * (1.0 - f));

  switch (i) {
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
      // i == 5, and also i == 6 from a quantised hue of 360.
      out[0] = v;
      out[1] = p;
      out[2] = q;
  }
}

/// `nearestLevel0(col)` — hue, in degrees, to one of four bands.
///
/// The partition is lopsided: **0-140** (red, orange, yellow, green) all
/// collapse to 140, a sliver to 160, 160-240 to 240, and 240-360 to 360. Run
/// through `hsvDegreesToRgb` those four bands are only four hues — green,
/// green-cyan, blue, magenta — so the toon pass has a four-colour palette and
/// nothing else.
///
/// Which means skin, at roughly 20-40 degrees, comes out **green**: the first
/// band swallows the entire warm half of the wheel. That sounds ruinous and
/// is not, because celFace's composite keeps only luma — and green carries the
/// largest luma weight (0.587), so the effect is a toon face rendered slightly
/// *brighter* than a neutral desaturation would give. The magenta band only
/// catches lips and strong pinks.
double nearestHueLevel(double col) {
  if (col <= 140.0) return 140.0;
  if (col <= 160.0) return 160.0;
  if (col <= 240.0) return 240.0;
  return 360.0;
}

/// `nearestLevel1(col)` — saturation to six levels.
///
/// The comment in the original lists seven (`0.0, 0.15, 0.3, 0.45, 0.6, 0.8,
/// 1.0`) but the code never returns 0: the first branch rounds everything below
/// 0.15 *up*. Grey can therefore not stay grey, which is part of why the toon
/// face has colour at all.
double nearestSaturationLevel(double col) {
  if (col <= 0.15) return 0.15;
  if (col <= 0.3) return 0.3;
  if (col <= 0.45) return 0.45;
  if (col <= 0.6) return 0.6;
  if (col <= 0.8) return 0.8;
  return 1.0;
}

/// `nearestLevel2(col)` — value to three levels.
///
/// This is the quantiser that does the visible work. Since the final composite
/// throws hue and saturation away and keeps luma, three brightness bands are
/// what the viewer actually sees as posterisation — the hue and saturation
/// levels only reach the screen by nudging that luma up or down.
double nearestValueLevel(double col) {
  if (col <= 0.3) return 0.3;
  if (col <= 0.6) return 0.6;
  return 1.0;
}
