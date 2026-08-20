// The slice of three.js maths the Jeeliz demos actually touch, in Dart.
//
// Storage and sign conventions are three.js's, deliberately: Mat4 is
// column-major (`m[col * 4 + row]`, the same layout `Matrix4.elements` uses),
// the coordinate system is right-handed, and the camera looks down -Z. Keeping
// those identical is what lets the ported demo code carry its magic numbers
// over untouched — `position.set(0, dy, 0.4)` means the same thing here as it
// does in main.js.

import 'dart:math' as math;
import 'dart:typed_data';

class Vec2 {
  const Vec2(this.x, this.y);
  final double x, y;

  @override
  String toString() => 'Vec2($x, $y)';
}

class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x, y, z;

  static const zero = Vec3(0, 0, 0);
  static const one = Vec3(1, 1, 1);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator -() => Vec3(-x, -y, -z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get lengthSq => x * x + y * y + z * z;
  double get length => math.sqrt(lengthSq);

  Vec3 get normalized {
    final l = length;
    return l < 1e-12 ? zero : Vec3(x / l, y / l, z / l);
  }

  /// `three.Vector3.applyEuler` — builds the rotation for [e] and applies it.
  Vec3 applyEuler(Euler e) => Mat4.rotationFromEuler(e).transformDirection(this);

  Vec3 lerp(Vec3 o, double t) =>
      Vec3(x + (o.x - x) * t, y + (o.y - y) * t, z + (o.z - z) * t);

  @override
  String toString() => 'Vec3(${x.toStringAsFixed(4)}, '
      '${y.toStringAsFixed(4)}, ${z.toStringAsFixed(4)})';
}

/// Intrinsic Euler angles in radians, with three.js's order semantics:
/// [EulerOrder.zyx] means `R = Rz · Ry · Rx`.
enum EulerOrder { xyz, zyx }

class Euler {
  const Euler(this.x, this.y, this.z, [this.order = EulerOrder.xyz]);

  final double x, y, z;
  final EulerOrder order;

  static const zero = Euler(0, 0, 0);
}

/// Column-major 4x4, matching `three.Matrix4.elements`.
class Mat4 {
  Mat4._(this.m);

  Mat4.identity() : m = Float64List(16) {
    m[0] = 1;
    m[5] = 1;
    m[10] = 1;
    m[15] = 1;
  }

  /// From 16 numbers in **column-major** order, which is both three's
  /// `Matrix4.elements` layout and glTF's `node.matrix` layout, so a glTF
  /// matrix goes straight in.
  factory Mat4.fromList(List<double> values) {
    if (values.length != 16) {
      throw ArgumentError('Mat4.fromList wants 16 values, got ${values.length}');
    }
    return Mat4._(Float64List.fromList(values));
  }

  final Float64List m;

  Mat4 clone() => Mat4._(Float64List.fromList(m));

  /// `this · other`, i.e. [other] is applied first.
  Mat4 operator *(Mat4 o) {
    final a = m, b = o.m;
    final r = Float64List(16);
    for (var c = 0; c < 4; c++) {
      final b0 = b[c * 4], b1 = b[c * 4 + 1], b2 = b[c * 4 + 2], b3 = b[c * 4 + 3];
      r[c * 4] = a[0] * b0 + a[4] * b1 + a[8] * b2 + a[12] * b3;
      r[c * 4 + 1] = a[1] * b0 + a[5] * b1 + a[9] * b2 + a[13] * b3;
      r[c * 4 + 2] = a[2] * b0 + a[6] * b1 + a[10] * b2 + a[14] * b3;
      r[c * 4 + 3] = a[3] * b0 + a[7] * b1 + a[11] * b2 + a[15] * b3;
    }
    return Mat4._(r);
  }

  /// Full transform including translation, then perspective divide is the
  /// caller's job — this returns the affine result only.
  Vec3 transformPoint(Vec3 v) => Vec3(
        m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
        m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
        m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
      );

  /// Rotation/scale only — translation is skipped, as for a direction vector.
  Vec3 transformDirection(Vec3 v) => Vec3(
        m[0] * v.x + m[4] * v.y + m[8] * v.z,
        m[1] * v.x + m[5] * v.y + m[9] * v.z,
        m[2] * v.x + m[6] * v.y + m[10] * v.z,
      );

  /// Projects [v] and returns `(x, y, z, w)` in clip space. The w component is
  /// what the near-plane clipper and the perspective divide both need, so it
  /// has to escape the Vec3 API.
  Float64List transformToClip(Vec3 v) {
    final out = Float64List(4);
    out[0] = m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12];
    out[1] = m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13];
    out[2] = m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14];
    out[3] = m[3] * v.x + m[7] * v.y + m[11] * v.z + m[15];
    return out;
  }

  static Mat4 rotationFromEuler(Euler e) {
    final r = Mat4.identity();
    final te = r.m;
    final a = math.cos(e.x), b = math.sin(e.x);
    final c = math.cos(e.y), d = math.sin(e.y);
    final f = math.cos(e.z), g = math.sin(e.z);

    switch (e.order) {
      case EulerOrder.xyz:
        final ae = a * f, af = a * g, be = b * f, bf = b * g;
        te[0] = c * f;
        te[4] = -c * g;
        te[8] = d;
        te[1] = af + be * d;
        te[5] = ae - bf * d;
        te[9] = -b * c;
        te[2] = bf - ae * d;
        te[6] = be + af * d;
        te[10] = a * c;
      case EulerOrder.zyx:
        final ae = a * f, af = a * g, be = b * f, bf = b * g;
        te[0] = c * f;
        te[4] = be * d - af;
        te[8] = ae * d + bf;
        te[1] = c * g;
        te[5] = bf * d + ae;
        te[9] = af * d - be;
        te[2] = -d;
        te[6] = c * b;
        te[10] = c * a;
    }
    return r;
  }

  /// `three.Matrix4.compose`, with the rotation supplied as Euler angles
  /// (every Jeeliz demo drives objects through `.rotation.set`, never a
  /// quaternion) and scale kept uniform-friendly but per-axis capable.
  static Mat4 compose(Vec3 position, Euler rotation, Vec3 scale) {
    final r = rotationFromEuler(rotation);
    final te = r.m;
    te[0] *= scale.x;
    te[1] *= scale.x;
    te[2] *= scale.x;
    te[4] *= scale.y;
    te[5] *= scale.y;
    te[6] *= scale.y;
    te[8] *= scale.z;
    te[9] *= scale.z;
    te[10] *= scale.z;
    te[12] = position.x;
    te[13] = position.y;
    te[14] = position.z;
    return r;
  }

  /// `three.PerspectiveCamera.updateProjectionMatrix` ends here. Note the
  /// argument order is three's (top before bottom), not OpenGL's.
  static Mat4 perspective(double left, double right, double top, double bottom,
      double near, double far) {
    final r = Mat4._(Float64List(16));
    final te = r.m;
    final x = 2 * near / (right - left);
    final y = 2 * near / (top - bottom);
    final a = (right + left) / (right - left);
    final b = (top + bottom) / (top - bottom);
    final c = -(far + near) / (far - near);
    final d = -2 * far * near / (far - near);

    te[0] = x;
    te[8] = a;
    te[5] = y;
    te[9] = b;
    te[10] = c;
    te[14] = d;
    te[11] = -1;
    return r;
  }

  /// General inverse. The Jeeliz camera never leaves the origin so the view
  /// matrix is identity in practice, but a filter that moves the camera would
  /// silently break without this.
  Mat4? get inverted {
    final me = m;
    final r = Float64List(16);

    final n11 = me[0], n21 = me[1], n31 = me[2], n41 = me[3];
    final n12 = me[4], n22 = me[5], n32 = me[6], n42 = me[7];
    final n13 = me[8], n23 = me[9], n33 = me[10], n43 = me[11];
    final n14 = me[12], n24 = me[13], n34 = me[14], n44 = me[15];

    final t11 = n23 * n34 * n42 -
        n24 * n33 * n42 +
        n24 * n32 * n43 -
        n22 * n34 * n43 -
        n23 * n32 * n44 +
        n22 * n33 * n44;
    final t12 = n14 * n33 * n42 -
        n13 * n34 * n42 -
        n14 * n32 * n43 +
        n12 * n34 * n43 +
        n13 * n32 * n44 -
        n12 * n33 * n44;
    final t13 = n13 * n24 * n42 -
        n14 * n23 * n42 +
        n14 * n22 * n43 -
        n12 * n24 * n43 -
        n13 * n22 * n44 +
        n12 * n23 * n44;
    final t14 = n14 * n23 * n32 -
        n13 * n24 * n32 -
        n14 * n22 * n33 +
        n12 * n24 * n33 +
        n13 * n22 * n34 -
        n12 * n23 * n34;

    final det = n11 * t11 + n21 * t12 + n31 * t13 + n41 * t14;
    if (det.abs() < 1e-18) return null;
    final di = 1.0 / det;

    r[0] = t11 * di;
    r[1] = (n24 * n33 * n41 -
            n23 * n34 * n41 -
            n24 * n31 * n43 +
            n21 * n34 * n43 +
            n23 * n31 * n44 -
            n21 * n33 * n44) *
        di;
    r[2] = (n22 * n34 * n41 -
            n24 * n32 * n41 +
            n24 * n31 * n42 -
            n21 * n34 * n42 -
            n22 * n31 * n44 +
            n21 * n32 * n44) *
        di;
    r[3] = (n23 * n32 * n41 -
            n22 * n33 * n41 -
            n23 * n31 * n42 +
            n21 * n33 * n42 +
            n22 * n31 * n43 -
            n21 * n32 * n43) *
        di;

    r[4] = t12 * di;
    r[5] = (n13 * n34 * n41 -
            n14 * n33 * n41 +
            n14 * n31 * n43 -
            n11 * n34 * n43 -
            n13 * n31 * n44 +
            n11 * n33 * n44) *
        di;
    r[6] = (n14 * n32 * n41 -
            n12 * n34 * n41 -
            n14 * n31 * n42 +
            n11 * n34 * n42 +
            n12 * n31 * n44 -
            n11 * n32 * n44) *
        di;
    r[7] = (n12 * n33 * n41 -
            n13 * n32 * n41 +
            n13 * n31 * n42 -
            n11 * n33 * n42 -
            n12 * n31 * n43 +
            n11 * n32 * n43) *
        di;

    r[8] = t13 * di;
    r[9] = (n14 * n23 * n41 -
            n13 * n24 * n41 -
            n14 * n21 * n43 +
            n11 * n24 * n43 +
            n13 * n21 * n44 -
            n11 * n23 * n44) *
        di;
    r[10] = (n12 * n24 * n41 -
            n14 * n22 * n41 +
            n14 * n21 * n42 -
            n11 * n24 * n42 -
            n12 * n21 * n44 +
            n11 * n22 * n44) *
        di;
    r[11] = (n13 * n22 * n41 -
            n12 * n23 * n41 -
            n13 * n21 * n42 +
            n11 * n23 * n42 +
            n12 * n21 * n43 -
            n11 * n22 * n43) *
        di;

    r[12] = t14 * di;
    r[13] = (n13 * n24 * n31 -
            n14 * n23 * n31 +
            n14 * n21 * n33 -
            n11 * n24 * n33 -
            n13 * n21 * n34 +
            n11 * n23 * n34) *
        di;
    r[14] = (n14 * n22 * n31 -
            n12 * n24 * n31 -
            n14 * n21 * n32 +
            n11 * n24 * n32 +
            n12 * n21 * n34 -
            n11 * n22 * n34) *
        di;
    r[15] = (n12 * n23 * n31 -
            n13 * n22 * n31 +
            n13 * n21 * n32 -
            n11 * n23 * n32 -
            n12 * n21 * n33 +
            n11 * n22 * n33) *
        di;

    return Mat4._(r);
  }

  /// Upper-left 3x3, inverse-transposed and packed row-major into 9 doubles.
  /// This is `three`'s `normalMatrix`: it keeps normals perpendicular to the
  /// surface under non-uniform scale, which a plain rotation would not.
  Float64List get normalMatrix3 {
    final a = m;
    final a00 = a[0], a01 = a[4], a02 = a[8];
    final a10 = a[1], a11 = a[5], a12 = a[9];
    final a20 = a[2], a21 = a[6], a22 = a[10];

    final b01 = a22 * a11 - a12 * a21;
    final b11 = -a22 * a10 + a12 * a20;
    final b21 = a21 * a10 - a11 * a20;

    final det = a00 * b01 + a01 * b11 + a02 * b21;

    // A flattened axis makes the matrix singular and the inverse-transpose
    // meaningless. casa_de_papel hits this for real: its bills are set
    // `scale.z = xRand * 10`, which lands arbitrarily close to zero on a flat
    // plane where the Z scale is visually irrelevant anyway. Falling back to
    // the plain upper-left 3x3 keeps the normal pointing the right way (it is
    // correct up to scale for a rotation, and shaders normalise) instead of
    // producing infinities.
    if (det.abs() < 1e-12) {
      final o = Float64List(9);
      o[0] = a00;
      o[1] = a01;
      o[2] = a02;
      o[3] = a10;
      o[4] = a11;
      o[5] = a12;
      o[6] = a20;
      o[7] = a21;
      o[8] = a22;
      return o;
    }

    final di = 1.0 / det;

    // inverse, then transpose, fused: out[row][col] = inv[col][row].
    final o = Float64List(9);
    o[0] = b01 * di;
    o[3] = b11 * di;
    o[6] = b21 * di;
    o[1] = (-a22 * a01 + a02 * a21) * di;
    o[4] = (a22 * a00 - a02 * a20) * di;
    o[7] = (-a21 * a00 + a01 * a20) * di;
    o[2] = (a12 * a01 - a02 * a11) * di;
    o[5] = (-a12 * a00 + a02 * a10) * di;
    o[8] = (a11 * a00 - a01 * a10) * di;
    return o;
  }
}

/// Applies a row-major 3x3 (as produced by [Mat4.normalMatrix3]) to [v].
Vec3 applyMat3(Float64List n, Vec3 v) => Vec3(
      n[0] * v.x + n[1] * v.y + n[2] * v.z,
      n[3] * v.x + n[4] * v.y + n[5] * v.z,
      n[6] * v.x + n[7] * v.y + n[8] * v.z,
    );

double clampd(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

double smoothstep(double edge0, double edge1, double x) {
  if (edge1 - edge0 == 0) return x < edge0 ? 0 : 1;
  final t = clampd((x - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
}
