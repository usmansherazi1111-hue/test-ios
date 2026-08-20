// Port of demos/threejs/celFace — your face redrawn as a cel-shaded cartoon.
//
// The first port that needs a render-to-texture *chain*. The demo runs four
// passes, and each one is doing something the previous one could not:
//
//   scene0 -> target0   the low-poly head, toonified (see cel_material.dart).
//                       Opaque inside the silhouette, cleared outside — so the
//                       alpha channel of this target *is* the head's shape.
//   scene1 -> target1   7-tap Gaussian on alpha only, horizontally.
//   scene2 -> target2   the same, vertically.
//   scene  -> screen    the video, with target2 mixed over it: reduced to luma
//                       and re-tinted a warm ivory.
//
// Two lines carry the whole effect.
//
// The first is in the blur: `if (colCenter.a == 0.0) { alphaBlured = colCenter.a; }`
// — a pixel that was outside the mask stays outside. Without it the blur would
// spread the mask outward into a halo; with it the feather can only eat
// *inward*, so the toon face shrinks slightly and its border dissolves into the
// real camera image instead of ending on a polygon edge. That is why the low
// poly count never shows.
//
// The second is in the composite: `dot(LUMA, faceColor.rgb) * FACECOLOR`. All
// the hue and saturation quantisation the cel shader just did is thrown away
// and replaced with one warm off-white. What survives is brightness — three
// posterised bands — plus the black edges. Cartoon ink and paper, not a
// colour-quantised photograph.
//
// The final composite needs no port at all: `mix(videoColor, faceColorTweaked,
// faceColor.a)` is source-over with straight alpha, which is exactly what
// Flutter does when it composites this overlay onto the camera preview
// underneath. So the last pass reduces to writing the tinted colour and the
// blurred alpha into the framebuffer, and the demo's full-screen video quad
// disappears.

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/scene.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';
import '../render/renderer.dart';
import '../tracking/face_filter_helper.dart';
import 'cel_material.dart';
import 'filter.dart';

class CelFaceFilter extends JeelizFilter {
  CelFaceFilter({
    this.mirrorVideo = true,
    this.blurEdgeSoftness = 10.0,
    this.blurReferenceHeightPx = 600.0,
  });

  /// Must match the overlay's mirroring.
  final bool mirrorVideo;

  /// `SETTINGS.blurEdgeSoftness = 10`, the multiplier on the blur's tap
  /// spacing. Higher means a wider, softer border — and, because the feather
  /// only goes inward, a smaller toon face.
  final double blurEdgeSoftness;

  /// The demo's tap spacing is `blurEdgeSoftness / canvasSize`, in canvas
  /// pixels, and its canvas is sized to the video. Here the render target is
  /// whatever `maxRenderDimension` says, and that is on a slider — so taking
  /// the spacing straight in target pixels would make the feather four times
  /// wider at 240 than at 960 and change how the filter looks. The spacing is
  /// scaled against this reference height instead, so the border is the same
  /// fraction of the face at every render resolution.
  ///
  /// Set it equal to the render height to get the demo's literal behaviour.
  final double blurReferenceHeightPx;

  /// `THREEFACEOBJ3DPIVOTED.scale.set(1.1, 1.1, 1.1)`.
  static const double kPivotedScale = 1.1;

  /// `threeMask.scale.multiplyScalar(1.2)`.
  static const double kMaskScale = 1.2;

  /// `threeMask.position.set(0, 0.2, -0.5)`.
  static const Vec3 kMaskPosition = Vec3(0, 0.2, -0.5);

  /// `const vec3 LUMA = vec3(0.299, 0.587, 0.114);`
  static const double kLumaR = 0.299, kLumaG = 0.587, kLumaB = 0.114;

  /// `const vec3 FACECOLOR = 1.2 * vec3(242.0, 236.0, 230.0) / 255.0;`
  ///
  /// A warm off-white, deliberately over 1 on the red channel (1.2*242/255 =
  /// 1.139) so the brightest band clips to white and the mid bands stay cream.
  /// The clip is not a bug; it is what makes highlights read as paper.
  static const double kFaceColorR = 1.2 * 242.0 / 255.0;
  static const double kFaceColorG = 1.2 * 236.0 / 255.0;
  static const double kFaceColorB = 1.2 * 230.0 / 255.0;

  /// The blur kernel, `8, 28, 56, 70, 56, 28, 8` over 254.
  ///
  /// Those are the binomial coefficients of row 8 of Pascal's triangle with its
  /// two outermost terms (1 and 1) dropped, which is why the divisor is 254 and
  /// not 256. Two missing units out of 256 is a 0.8% shortfall, so the blur
  /// very slightly *brightens* alpha — immaterial next to the `pow(a, 2)` that
  /// follows it.
  static const List<double> kBlurWeights = <double>[
    8 / 254,
    28 / 254,
    56 / 254,
    70 / 254,
    56 / 254,
    28 / 254,
    8 / 254,
  ];

  Object3D? _pivoted;
  CelFaceMaterial? _material;
  BufferGeometry? _geometry;

  /// Scratch buffers for the two blur passes, grown on demand.
  Float32List? _alphaA;
  Float32List? _alphaB;

  /// The material, for tests and for a debug view that wants the raw toon pass.
  CelFaceMaterial? get material => _material;

  @override
  bool get needsVideo => true;

  /// The cel shader works in HSV and the composite takes a luma-weighted dot
  /// product, so this one genuinely needs the YUV->RGB conversion.
  @override
  bool get needsVideoColor => true;

  @override
  Future<void> load() async {
    final json = await loadJeelizAssetString('celFace/faceLowPoly.json');
    // `decodeBufferGeometry` computes smooth normals when the export ships
    // none, which is the original's `computeVertexNormals()` line. Kept for
    // fidelity even though the cel material never reads a normal — the cost is
    // once at load, and `CelFaceMaterial.needsNormals` is false so the renderer
    // does not carry a normal matrix per frame.
    _geometry = decodeBufferGeometry(json);
    _material = CelFaceMaterial(mirrorVideo: mirrorVideo);
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final geometry = _geometry;
    final material = _material;
    if (geometry == null || material == null) return;

    // The demo builds the pivot by hand — an outer object it positions and
    // rotates, and an inner one offset by -pivotOffsetYZ and scaled 1.1. The
    // shared helper already applies the pivot in `updatePoses`, so only the
    // scale is left to reproduce here.
    final pivoted = Object3D(name: 'celPivoted')
      ..scale = const Vec3(kPivotedScale, kPivotedScale, kPivotedScale);

    final mask = Mesh(geometry, material, name: 'celMask')
      ..scale = const Vec3(kMaskScale, kMaskScale, kMaskScale)
      ..position = kMaskPosition;

    pivoted.add(mask);
    helper.faceObject.add(pivoted);

    _pivoted = pivoted;
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final p = _pivoted;
    if (p != null) helper.faceObject.remove(p);
    _pivoted = null;
  }

  @override
  void setVideo(VideoLumaTexture? video) {
    _material?.video = video;
  }

  @override
  void postProcess(Framebuffer fb) {
    final w = fb.width, h = fb.height;
    final n = w * h;
    var a = _alphaA, b = _alphaB;
    if (a == null || a.length < n) {
      a = _alphaA = Float32List(n);
      b = _alphaB = Float32List(n);
    }
    b!;

    final color = fb.color;

    // Pull alpha out. The cel pass is opaque, so inside the mask the
    // framebuffer's premultiplied RGB is already the straight colour and needs
    // no un-premultiplying; outside, everything is zero.
    for (var i = 0; i < n; i++) {
      a[i] = color[i * 4 + 3] / 255.0;
    }

    // `dxy` is the *step between taps*, so the kernel reaches three of them
    // either side. Scaled off the reference height in both axes, as the demo
    // scales off its canvas — one number, so a non-square target gets the same
    // absolute feather horizontally and vertically.
    final scale = h / blurReferenceHeightPx;
    final step = math.max(1, (blurEdgeSoftness * scale).round());

    _blurAlpha(a, b, w, h, dx: step, dy: 0);
    _blurAlpha(b, a, w, h, dx: 0, dy: step);

    // Final composite. `mix(videoColor, faceColorTweaked, alpha)` is left to
    // Flutter — this writes the tinted colour premultiplied by the blurred
    // alpha, and the camera preview supplies the other half of the mix.
    for (var i = 0; i < n; i++) {
      final alpha = a[i];
      final o = i * 4;
      if (alpha <= 0) {
        color[o] = color[o + 1] = color[o + 2] = color[o + 3] = 0;
        continue;
      }

      // The blur passes carried `colCenter.rgb` through untouched, so this is
      // still the cel pass's colour.
      final gray = color[o] * kLumaR + color[o + 1] * kLumaG + color[o + 2] * kLumaB;

      // gray is in 0..255 already, so the tint multiplies straight onto it —
      // and then by alpha, to premultiply.
      final k = alpha;
      color[o] = _clamp255(gray * kFaceColorR * k);
      color[o + 1] = _clamp255(gray * kFaceColorG * k);
      color[o + 2] = _clamp255(gray * kFaceColorB * k);
      color[o + 3] = _clamp255(alpha * 255.0);
    }
  }

  /// One separable pass of the demo's blur material.
  ///
  /// ```glsl
  /// float alphaBlured = (8./254.)*texture2D(samplerImage, vUV-3.*dxy).a + ... ;
  /// if (colCenter.a == 0.0) { alphaBlured = colCenter.a; }
  /// gl_FragColor = vec4(colCenter.rgb, pow(alphaBlured, 2.));
  /// ```
  ///
  /// The guard is the whole trick — see the file header. `pow(a, 2)` runs on
  /// *each* pass, so the two together are a fourth power, which pulls the
  /// feather in hard: a pixel at half coverage after both blurs ends at 6% of
  /// its original alpha.
  ///
  /// Taps outside the target clamp to the edge, as `THREE.ClampToEdgeWrapping`
  /// does on a render target.
  static void _blurAlpha(Float32List src, Float32List dst, int w, int h,
      {required int dx, required int dy}) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        final centre = src[i];
        if (centre == 0.0) {
          dst[i] = 0.0;
          continue;
        }

        var sum = 0.0;
        for (var k = -3; k <= 3; k++) {
          var tx = x + k * dx;
          var ty = y + k * dy;
          if (tx < 0) {
            tx = 0;
          } else if (tx >= w) {
            tx = w - 1;
          }
          if (ty < 0) {
            ty = 0;
          } else if (ty >= h) {
            ty = h - 1;
          }
          sum += kBlurWeights[k + 3] * src[ty * w + tx];
        }

        dst[i] = sum * sum;
      }
    }
  }

  static int _clamp255(double v) {
    final i = v.round();
    return i < 0 ? 0 : (i > 255 ? 255 : i);
  }
}
