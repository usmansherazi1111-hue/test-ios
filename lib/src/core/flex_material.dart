// Port of libs/three/customMaterials/FlexMaterial/ThreeFlexMaterial.js.
//
// This is what makes the dog's ears flop, and it is a lovely trick. Take the
// Phong shader and replace only `<project_vertex>`:
//
// ```glsl
// vec4 worldPosition        = modelMatrix        * vec4(transformed, 1.0);
// vec4 worldPositionDelayed = modelMatrixDelayed * vec4(transformed, 1.0);
// worldPosition = mix(worldPosition, worldPositionDelayed,
//                     texture2D(flexMap, uv).r);
// gl_Position = projectionMatrix * viewMatrix * worldPosition;
// ```
//
// Every vertex is placed twice — once by the mesh's real world matrix, once by
// a matrix that *lags* behind it — and the flex map's red channel says which
// one wins. Where the map is black the vertex is welded to the head; where it
// is white the vertex trails. Paint the map dark at the ear root and light at
// the tip and the ears swing on their own.
//
// The lag itself is `set_amortized()`: exponential smoothing of position, scale
// and Euler angles toward the target, with the smoothing factor as the caller's
// "amortization" (0.1 for the ears, 0.3 for the tongue — smaller lags more).

import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec_mat.dart';
import 'standard_materials.dart';
import 'texture.dart';

class FlexMaterial extends PhongMaterial {
  FlexMaterial({
    required this.flexMap,
    super.color,
    super.map,
    super.bumpMap,
    super.bumpScale,
    super.alphaMap,
    super.specular,
    super.shininess,
    super.opacity,
    super.transparent,
    super.side,
  });

  /// Red channel is the blend weight: 0 follows the head exactly, 1 lags fully.
  Texture2D flexMap;

  /// The lagged model matrix. Identity until [setAmortized] first runs, which
  /// would weld everything to the origin — so the flex blend is skipped until
  /// then.
  Mat4 _delayed = Mat4.identity();
  bool _initialised = false;

  Vec3 _posDelayed = Vec3.zero;
  Vec3 _scaleDelayed = Vec3.one;
  Vec3 _eulerDelayed = Vec3.zero;

  @override
  bool get overridesWorldPosition => _initialised;

  final Float64List _flexTexel = Float64List(4);

  /// `set_amortized(positionTarget, scaleTarget, eulerTarget, parentMatrix,
  /// amortization)`.
  ///
  /// Call once per frame with the mesh's *world* position/scale/rotation. On the
  /// first call the lagged state snaps to the target instead of easing in from
  /// nothing.
  ///
  /// Note the original smooths **Euler angles** component-wise rather than
  /// quaternions. That is not a rotation-correct interpolation, but it is what
  /// produces the demo's particular wobble, so it is reproduced as-is.
  void setAmortized({
    required Vec3 position,
    required Vec3 scale,
    required Vec3 euler,
    required double amortization,
    Mat4? parentMatrix,
  }) {
    if (!_initialised) {
      _posDelayed = position;
      _scaleDelayed = scale;
      _eulerDelayed = euler;
      _initialised = true;
    }

    _eulerDelayed = _mix(_eulerDelayed, euler, amortization);
    _posDelayed = _mix(_posDelayed, position, amortization);
    _scaleDelayed = _mix(_scaleDelayed, scale, amortization);

    // The original builds this as rotation, then setPosition, then scale —
    // i.e. compose(position, rotation, scale), the same order Mat4.compose uses.
    var m = Mat4.compose(
      _posDelayed,
      Euler(_eulerDelayed.x, _eulerDelayed.y, _eulerDelayed.z),
      _scaleDelayed,
    );
    if (parentMatrix != null) m = parentMatrix * m;
    _delayed = m;
  }

  /// Undo initialisation, so the next [setAmortized] snaps rather than eases.
  void resetAmortization() => _initialised = false;

  static Vec3 _mix(Vec3 a, Vec3 b, double t) => Vec3(
        b.x * t + a.x * (1 - t),
        b.y * t + a.y * (1 - t),
        b.z * t + a.z * (1 - t),
      );

  @override
  void worldPosition(double x, double y, double z, double u, double v,
      Mat4 model, Float64List out) {
    final a = model.m, d = _delayed.m;

    final wx = a[0] * x + a[4] * y + a[8] * z + a[12];
    final wy = a[1] * x + a[5] * y + a[9] * z + a[13];
    final wz = a[2] * x + a[6] * y + a[10] * z + a[14];

    flexMap.sample(u, v, _flexTexel);
    final t = _flexTexel[0];
    if (t <= 0.0) {
      out[0] = wx;
      out[1] = wy;
      out[2] = wz;
      return;
    }

    final dx = d[0] * x + d[4] * y + d[8] * z + d[12];
    final dy = d[1] * x + d[5] * y + d[9] * z + d[13];
    final dz = d[2] * x + d[6] * y + d[10] * z + d[14];

    out[0] = wx + (dx - wx) * t;
    out[1] = wy + (dy - wy) * t;
    out[2] = wz + (dz - wz) * t;
  }
}

/// Decomposes a world matrix into the position / scale / Euler triple
/// [FlexMaterial.setAmortized] wants.
///
/// The demo gets these from `getWorldPosition` / `getWorldScale` /
/// `getWorldQuaternion` — and passes an `Euler` where a `Quaternion` is
/// expected, which happens to work in three because `Euler` also has
/// `setFromRotationMatrix`. So Euler angles are what actually get smoothed.
({Vec3 position, Vec3 scale, Vec3 euler}) decomposeWorldMatrix(Mat4 m) {
  final e = m.m;
  final position = Vec3(e[12], e[13], e[14]);

  final sx = Vec3(e[0], e[1], e[2]).length;
  final sy = Vec3(e[4], e[5], e[6]).length;
  final sz = Vec3(e[8], e[9], e[10]).length;
  final scale = Vec3(sx, sy, sz);

  // Unscale before reading angles out.
  final ix = sx < 1e-12 ? 0.0 : 1.0 / sx;
  final iy = sy < 1e-12 ? 0.0 : 1.0 / sy;
  final iz = sz < 1e-12 ? 0.0 : 1.0 / sz;

  final m11 = e[0] * ix, m12 = e[4] * iy, m13 = e[8] * iz;
  final m22 = e[5] * iy, m23 = e[9] * iz;
  final m32 = e[6] * iy, m33 = e[10] * iz;

  // three's Euler.setFromRotationMatrix, default XYZ order.
  final y = math.asin(clampd(m13, -1, 1));
  double x, z;
  if (m13.abs() < 0.9999999) {
    x = math.atan2(-m23, m33);
    z = math.atan2(-m12, m11);
  } else {
    x = math.atan2(m32, m22);
    z = 0;
  }
  return (position: position, scale: scale, euler: Vec3(x, y, z));
}
