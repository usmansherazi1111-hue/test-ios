// Port of `build_customMaskMaterial()` from demos/threejs/tiger/main.js.
//
// This is three's Lambert shader with two injections. The vertex stage swings
// the lower jaw:
//
// ```glsl
// float isLowerJaw = step(position.y + position.z*0.2, 0.0);
// float theta = isLowerJaw * mouthOpening * 3.14/12.0;
// transformed.yz = mat2(cos(theta), sin(theta), -sin(theta), cos(theta)) * transformed.yz;
// ```
//
// and the fragment stage replaces the mask with camera video wherever the mask
// should "disappear" — around the eyes, and only where the texture is light:
//
// ```glsl
// float alphaMask = 1.0;
// vec2 pointToEyeL = vPos.xy - vec2(0.25, 0.15);
// vec2 pointToEyeR = vPos.xy - vec2(-0.25, 0.15);
// alphaMask *= smoothstep(0.05, 0.2, length(vec2(0.6,1.)*pointToEyeL));
// alphaMask *= smoothstep(0.05, 0.2, length(vec2(0.6,1.)*pointToEyeR));
// alphaMask = max(alphaMask, smoothstep(0.65, 0.75, vPos.z));
// float isDark = step(dot(texelColor.rgb, vec3(1.,1.,1.)), 1.0);
// alphaMask = mix(alphaMask, 1., isDark);
// ...
// gl_FragColor = mix(videoColor, gl_FragColor, alphaMask);
// ```
//
// Note the last line: the result is **opaque everywhere**. The eye holes are
// not transparency — they are the camera image, displaced and tinted orange,
// painted by the mask itself. That is why this filter needs a video texture at
// all, and why it looks wrong (black eye sockets) without one.

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/material.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';

class TigerMaskMaterial extends Material {
  TigerMaskMaterial({
    required this.map,
    this.diffuse = const Vec3(0xee / 255, 0xee / 255, 0xee / 255),
    this.video,
    this.videoTint = const Vec3(1.5, 0.6, 0.0),
  });

  /// The face texture. `headTexture2.png` for the skin, a 1x1 white pixel for
  /// the eyes.
  Texture2D map;

  /// three's `UniformsLib.common.diffuse` default is 0xeeeeee, and the demo
  /// never overrides it — the ShaderMaterial inherits `ShaderLib.lambert
  /// .uniforms` wholesale. Not white, slightly under.
  Vec3 diffuse;

  /// Camera luma. Null before the first frame arrives, in which case the
  /// video term reads as black, exactly as an unbound sampler would.
  VideoLumaTexture? video;

  /// `videoColorGS * vec3(1.5, 0.6, 0.0)` — grayscale video pushed to orange.
  Vec3 videoTint;

  /// 0..1. Drives the jaw rotation in the vertex stage.
  double mouthOpening = 0;

  /// Mirrors the overlay: when the preview is mirrored, the video lookup has
  /// to be mirrored with it or the displaced wash slides the wrong way.
  bool mirrorVideo = false;

  /// The original declares `transparent: true`, but look at what the shader
  /// actually writes: `mix(videoColor, gl_FragColor, alphaMask)` where both
  /// inputs have alpha 1, so the output alpha is provably 1 for every
  /// fragment. Blending is therefore a no-op, and declaring it opaque keeps
  /// the mask in the pass where a depth buffer is most reliable instead of
  /// making it depend on per-object back-to-front ordering. Same image, fewer
  /// ways to get it wrong.
  @override
  bool get transparent => false;

  @override
  bool get deformsVertices => true;

  @override
  void deformVertex(double x, double y, double z, Float64List out) {
    // step(position.y + position.z*0.2, 0.0) — 1 for the lower jaw.
    final isLowerJaw = (y + z * 0.2) <= 0.0 ? 1.0 : 0.0;
    if (isLowerJaw == 0.0 || mouthOpening <= 0) {
      out[0] = x;
      out[1] = y;
      out[2] = z;
      return;
    }

    final theta = mouthOpening * math.pi / 12.0;
    final c = math.cos(theta), s = math.sin(theta);
    // GLSL mat2 is column-major: mat2(c, s, -s, c) rotates (y, z) by +theta.
    out[0] = x;
    out[1] = c * y - s * z;
    out[2] = s * y + c * z;
  }

  final Float64List _texel = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    map.sample(f.u, f.v, _texel);

    // <map_fragment>: diffuseColor *= texelColor
    final dr = diffuse.x * _texel[0];
    final dg = diffuse.y * _texel[1];
    final db = diffuse.z * _texel[2];

    final lit = lambertIrradiance(f);
    var cr = dr * lit.x, cg = dg * lit.y, cb = db * lit.z;

    // --- alpha mask, in object space -----------------------------------
    var alphaMask = 1.0;

    final el = _eyeFalloff(f.ox - 0.25, f.oy - 0.15);
    final er = _eyeFalloff(f.ox + 0.25, f.oy - 0.15);
    alphaMask *= el * er;

    // The nose is forced opaque so the muzzle does not dissolve.
    final nose = smoothstep(0.65, 0.75, f.oz);
    if (nose > alphaMask) alphaMask = nose;

    // Only the *light* parts of the texture are allowed to go see-through;
    // the dark stripes stay painted.
    final isDark = (_texel[0] + _texel[1] + _texel[2]) <= 1.0 ? 1.0 : 0.0;
    alphaMask = alphaMask + (1.0 - alphaMask) * isDark;

    if (alphaMask < 0.999) {
      // --- displaced video lookup --------------------------------------
      // scale = 0.03 / vPos.z, and uvMove = vec2(-sign(vPos.x), -1.5) * scale.
      //
      // The original works in gl_FragCoord space, whose Y counts from the
      // bottom; vpV counts from the top, so the -1.5 flips sign here.
      final z = f.oz.abs() < 1e-4 ? 1e-4 : f.oz;
      final scale = 0.03 / z;
      final sign = f.ox < 0 ? -1.0 : (f.ox > 0 ? 1.0 : 0.0);

      var u = f.vpU + -sign * scale;
      final v = f.vpV + 1.5 * scale;
      if (mirrorVideo) u = 1.0 - u;

      final vid = video;
      final gs = vid == null ? 0.0 : vid.sample(u, v);

      final vr = gs * videoTint.x, vg = gs * videoTint.y, vb = gs * videoTint.z;

      cr = vr + (cr - vr) * alphaMask;
      cg = vg + (cg - vg) * alphaMask;
      cb = vb + (cb - vb) * alphaMask;
    }

    out[0] = cr;
    out[1] = cg;
    out[2] = cb;
    // mix(videoColor.a = 1, gl_FragColor.a = 1, alphaMask) is 1 regardless:
    // the mask is opaque, and the "holes" are video it painted itself.
    out[3] = 1.0;
    return true;
  }

  /// `smoothstep(0.05, 0.2, length(vec2(0.6, 1.0) * pointToEye))` — an
  /// ellipse, wider than tall, centred on each eye.
  double _eyeFalloff(double dx, double dy) {
    final ex = 0.6 * dx;
    final d2 = ex * ex + dy * dy;
    // Most of the mask is nowhere near an eye, so settle the common case on
    // squared distance and keep the sqrt for the narrow transition band.
    if (d2 >= 0.04) return 1.0; // 0.2^2
    if (d2 <= 0.0025) return 0.0; // 0.05^2
    return smoothstep(0.05, 0.2, math.sqrt(d2));
  }
}
