// Port of demos/threejs/matrix — falling code, with your face inside it.
//
// Structurally this is the odd one out. Every other filter draws *over* the
// camera preview; this one replaces it. The demo's first move after building
// the scene is:
//
//   threeInstances.videoMesh.material.uniforms.samplerVideo.value = videoTexture;
//
// — reaching into JeelizThreeHelper's full-screen background quad and swapping
// the camera out for `matrixRain.mp4`. So the camera is never shown. It is only
// *sampled*, by the mask, as a green-keyed brightness signal.
//
// The mask itself is one shader doing three things at once:
//
//   * a green key of the camera, `luma * vec3(0, 1.5, 0)`, with a white
//     specular kick above 30% brightness;
//   * the rain again, sampled at UVs bent by `refract()` through the surface
//     normal, so the code appears to flow across a glass head;
//   * two fades, at the silhouette and at the neck, that dissolve both back
//     into the plain background.
//
// The last line is what makes it work:
//
//   finalColor = colorCamera * isInsideFace + colorLineCode;
//
// `colorLineCode` is added at full strength, un-attenuated. At the silhouette
// `isInsideFace` reaches 0 and the refraction is mixed out, so the mask's own
// pixels become *exactly* the background behind them. There is no edge to see.
//
// One thing in the original is wrong and inert. The vertex shader does
// `vNormalView = vec3(viewMatrix * vec4(normalize(transformedNormal), 0.))`,
// but `<defaultnormal_vertex>` has already put `transformedNormal` in view
// space — so the view matrix is applied twice. It costs nothing here because
// JeelizThreeHelper never moves or rotates its camera, leaving `viewMatrix` an
// identity. Transcribed as a single view-space normal.

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../core/texture.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';
import '../render/renderer.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';
import 'matrix_rain.dart';

const String _kAssetDir = 'matrix';

class MatrixFilter extends JeelizFilter {
  MatrixFilter({
    this.mirrorVideo = true,
    MatrixRain? rain,
  }) : rain = rain ?? MatrixRain();

  /// Must match the overlay's mirroring. The demo sets `CSSFlipX: true` on the
  /// whole canvas, so the rain is mirrored along with everything else — which
  /// rain does not mind. Only the camera sampling needs the flip undone.
  final bool mirrorVideo;

  /// The falling code. Synthesised rather than decoded — see matrix_rain.dart
  /// for why.
  final MatrixRain rain;

  /// `maskMesh.position.set(0, 0.3, -0.35)`.
  static const Vec3 kMaskPosition = Vec3(0, 0.3, -0.35);

  BufferGeometry? _geometry;
  MatrixMaskMaterial? _material;
  Mesh? _mask;

  /// The mask material, for tests.
  MatrixMaskMaterial? get material => _material;

  @override
  bool get needsVideo => true;

  /// The green key is `dot(colorCamera, LUMA)`, so brightness would do — but
  /// the demo reads `.rgb` and this port keeps the same input the shader had.
  @override
  bool get needsVideoColor => true;

  @override
  Future<void> load() async {
    _geometry = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/maskMesh.json'));
    // `maskGeometry.computeVertexNormals()` — and unlike celFace, this mesh's
    // normals are load-bearing: they drive both the silhouette fade and the
    // refraction.
    _material = MatrixMaskMaterial(rain: rain.texture, mirrorVideo: mirrorVideo);
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final geometry = _geometry;
    final material = _material;
    if (geometry == null || material == null) return;

    final mask = Mesh(geometry, material, name: 'matrixMask')
      ..position = kMaskPosition;
    helper.faceObject.add(mask);
    _mask = mask;
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final m = _mask;
    if (m != null) helper.faceObject.remove(m);
    _mask = null;
  }

  @override
  void setVideo(VideoLumaTexture? video) {
    _material?.video = video;
  }

  @override
  void update(DetectState state, double dt) {
    rain.update(dt);
  }

  /// The demo's background quad: `renderOrder = -1000`, no depth, the rain
  /// stretched across the viewport.
  ///
  /// `vUV = 0.5 + videoTransformMat2 * position` on a full-screen quad, which
  /// with a matching aspect is just the normalised screen position.
  @override
  void preRender(Framebuffer fb) {
    final tex = rain.texture;
    final texel = Float64List(4);
    final color = fb.color;
    final w = fb.width, h = fb.height;

    for (var y = 0; y < h; y++) {
      final v = (y + 0.5) / h;
      for (var x = 0; x < w; x++) {
        tex.sampleTopDown((x + 0.5) / w, v, texel);
        final i = (y * w + x) * 4;
        color[i] = (texel[0] * 255).round().clamp(0, 255);
        color[i + 1] = (texel[1] * 255).round().clamp(0, 255);
        color[i + 2] = (texel[2] * 255).round().clamp(0, 255);
        color[i + 3] = 255;
      }
    }
  }
}

/// The mask's fragment shader.
class MatrixMaskMaterial extends Material {
  MatrixMaskMaterial({
    required this.rain,
    this.video,
    this.mirrorVideo = false,
  });

  /// The falling-code texture the background is also drawn from.
  Texture2D rain;

  /// Camera frame. Null until the first one arrives.
  VideoLumaTexture? video;

  bool mirrorVideo;

  /// `float isNeck = 1. - smoothstep(-1.2, -0.85, vPosition.y);`
  ///
  /// Object-space, and the mesh runs from y = -1.28 to +0.85 — so this fades
  /// out the bottom two percent of it, which is the neck stump.
  static const double kNeckLow = -1.2, kNeckHigh = -0.85;

  /// `pow(length(vNormalView.xy), 3.)` — 0 facing the camera, 1 at the
  /// silhouette. The cube keeps the edge soft well into the profile.
  static const double kTangentPower = 3.0;

  /// `refract(vec3(0.,0.,-1.), vNormalView, 0.3)` and `uv + 0.1 * refracted.xy`.
  static const double kRefractEta = 0.3;
  static const double kRefractStrength = 0.1;

  /// `colorCamera = colorCameraVal * vec3(0.0, 1.5, 0.0);` — pure green, and
  /// over-driven, so a lit face clips into a solid green rather than shading.
  static const double kGreenGain = 1.5;

  /// `colorCamera += vec3(1.) * smoothstep(0.3, 0.6, colorCameraVal);`
  static const double kSpecularLow = 0.3, kSpecularHigh = 0.6;

  static const double kLumaR = 0.299, kLumaG = 0.587, kLumaB = 0.114;

  /// The mask is opaque: it writes the background back out wherever it is not
  /// the face, so there is nothing to blend with.
  @override
  bool get transparent => false;

  final Float64List _rgb = Float64List(3);
  final Float64List _texel = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    // `vNormalView` is normalised per *vertex* and then interpolated, so it is
    // slightly short inside a triangle. Left as it is rather than renormalised:
    // both `length(.xy)` and `refract` read it raw in the original.
    final nx = f.nx, ny = f.ny, nz = f.nz;

    final isNeck = 1.0 - smoothstep(kNeckLow, kNeckHigh, f.oy);
    final tangent = math.sqrt(nx * nx + ny * ny);
    final isTangent = tangent * tangent * tangent; // pow(x, 3)
    final isInsideFace = (1.0 - isTangent) * (1.0 - isNeck);

    // `vec2 uv = gl_FragCoord.xy / resolution;` — gl_FragCoord counts up from
    // the bottom, a raster row counts down, so the rain's v is flipped once
    // more below. The camera keeps the top-down v every other ported filter
    // uses.
    final u = f.vpU;
    final vTop = f.vpV;

    // refract(I, N, eta) with I = (0, 0, -1), so dot(N, I) = -N.z.
    final dotNI = -nz;
    final k = 1.0 - kRefractEta * kRefractEta * (1.0 - dotNI * dotNI);
    double rx = 0, ry = 0;
    if (k >= 0) {
      // eta*I - (eta*dot(N,I) + sqrt(k)) * N, xy only — I has no xy.
      final s = kRefractEta * dotNI + math.sqrt(k);
      rx = -s * nx;
      ry = -s * ny;
    }

    // `mix(uv, uvRefracted, smoothstep(0., 1., isInsideFace))`.
    final bend = smoothstep(0.0, 1.0, isInsideFace) * kRefractStrength;
    // The offset is in gl_FragCoord space, where +y is up; this buffer's v
    // counts down, so the y offset is subtracted rather than added.
    final ru = u + bend * rx;
    final rv = vTop - bend * ry;

    rain.sampleTopDown(ru, rv, _texel);
    final lineR = _texel[0], lineG = _texel[1], lineB = _texel[2];

    // The camera, green-keyed.
    var cameraU = u;
    if (mirrorVideo) cameraU = 1.0 - cameraU;
    final vid = video;
    if (vid == null) {
      _rgb[0] = _rgb[1] = _rgb[2] = 0;
    } else {
      vid.sampleRgb(cameraU, vTop, _rgb);
    }
    final val = _rgb[0] * kLumaR + _rgb[1] * kLumaG + _rgb[2] * kLumaB;

    final spec = smoothstep(kSpecularLow, kSpecularHigh, val);
    final camR = spec;
    final camG = val * kGreenGain + spec;
    final camB = spec;

    out[0] = camR * isInsideFace + lineR;
    out[1] = camG * isInsideFace + lineG;
    out[2] = camB * isInsideFace + lineB;
    out[3] = 1;
    return true;
  }
}
