// Face landmarks -> Jeeliz DetectState.
//
// Jeeliz's own tracker is a convolutional net evaluated in GLSL against
// obfuscated weights (neuralNets/NN_DEFAULT.json). There is no pure-Dart route
// to it, so this package takes landmarks from whatever tracker the host app
// already runs — MediaPipe FaceMesh, ARKit, ARCore — and synthesises the same
// seven numbers the net would have produced. Everything downstream is then the
// real Jeeliz pipeline.
//
// The conversion is metric, not fitted: solve a head pose from the landmarks,
// then work out where a unit cube would have to sit for its projection to
// match that head. The two constants which tie the two coordinate systems
// together ([JeelizCubeCalibration]) were read off the demo's own assets, not
// guessed — see the doc comments there.

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../core/scene.dart' show PerspectiveCamera;
import '../math/vec_mat.dart';
import 'detect_state.dart';

/// Canonical adult head in millimetres, keyed by MediaPipe FaceMesh index.
///
/// +X image right, +Y up, +Z out of the face towards the camera. Note 33/133
/// are the *subject's* right eye, which sits on the left of an un-mirrored
/// frame, hence the negative X.
///
/// Only the ratios matter: the solver recovers absolute scale, so a wider face
/// simply fits a larger scale factor.
const Map<int, Vec3> kCanonicalFace = {
  10: Vec3(0, 72, -18), // hairline centre
  152: Vec3(0, -66, 6), // chin, bottom
  199: Vec3(0, -54, 18), // chin, front
  1: Vec3(0, 2, 32), // nose tip
  6: Vec3(0, 28, 14), // nose bridge, mid
  168: Vec3(0, 36, 8), // sellion
  33: Vec3(-44, 34, -10), // right eye, outer
  133: Vec3(-16, 33, -2), // right eye, inner
  263: Vec3(44, 34, -10), // left eye, outer
  362: Vec3(16, 33, -2), // left eye, inner
  61: Vec3(-27, -30, 8), // mouth, right corner
  291: Vec3(27, -30, 8), // mouth, left corner
  234: Vec3(-72, 6, -52), // right side of head, in front of the ear
  454: Vec3(72, 6, -52), // left side of head, in front of the ear
};

/// Relates the demo's "unit cube" head space to canonical millimetres.
///
/// Both defaults are derived from `models3D/face.json` — the occluder the demo
/// itself aligns to the face — rather than tuned by eye:
///
/// * The occluder spans x = ±93.5 mesh units and main.js scales it by 0.0084,
///   so the head is ±0.785 cube units wide. The canonical model puts the sides
///   of the head (landmarks 234/454) at ±72 mm. 72 / 0.785 = **91.7**, i.e.
///   one cube unit is ~92 mm.
/// * main.js parents the glasses at `(0, 0.07, 0.4)` with scale 0.006, which
///   puts the lens centre at (0, 0.272, 0.512) cube units = (0, 25, 47) mm
///   from the cube origin. For the lenses to land on the eyes — canonical
///   (0, 34, ~15) — the origin must sit near **(0, 9, -32) mm**.
class JeelizCubeCalibration {
  const JeelizCubeCalibration({
    this.unitMm = 92.0,
    this.origin = const Vec3(0, 9, -32),
  });

  /// Canonical millimetres spanned by one cube unit.
  final double unitMm;

  /// Where the cube's origin sits in canonical face space.
  final Vec3 origin;
}

/// A solved head pose in image space: canonical mm -> pixels.
class LandmarkPose {
  const LandmarkPose(this.rows, this.scale, this.originPx);

  /// Rows map a canonical vector onto image x (right), image y (**down**) and
  /// depth (into the screen). Orthonormal, determinant +1.
  final List<Vec3> rows;

  /// Canonical millimetres -> source-image pixels.
  final double scale;

  /// Where the canonical centroid lands, in source-image pixels.
  final Offset originPx;

  Offset project(Vec3 p) {
    final d = p - _centroid;
    return Offset(rows[0].dot(d) * scale + originPx.dx,
        rows[1].dot(d) * scale + originPx.dy);
  }
}

final Vec3 _centroid = () {
  var sum = Vec3.zero;
  for (final p in kCanonicalFace.values) {
    sum = sum + p;
  }
  return sum * (1.0 / kCanonicalFace.length);
}();

/// Pose from Orthography and Scaling.
///
/// Under weak perspective `p ≈ s·R₂ₓ₃·(P − P̄) + p̄`, which is linear in the two
/// unknown rows and so solves in closed form from one symmetric 3x3 inverse.
/// The rows are then orthonormalised into a genuine rotation and their mean
/// length is the scale.
///
/// [normalized] is 0..1 in the upright source image.
LandmarkPose? solveLandmarkPose(
    List<Offset> normalized, double imgW, double imgH) {
  final pts = <Vec3>[];
  final obs = <Offset>[];

  for (final e in kCanonicalFace.entries) {
    if (e.key >= normalized.length) continue;
    final n = normalized[e.key];
    if (n.dx.isNaN || n.dy.isNaN) continue;
    pts.add(e.value);
    obs.add(Offset(n.dx * imgW, n.dy * imgH));
  }
  if (pts.length < 6) return null;

  var pbx = 0.0, pby = 0.0;
  for (final o in obs) {
    pbx += o.dx;
    pby += o.dy;
  }
  pbx /= obs.length;
  pby /= obs.length;

  var cb = Vec3.zero;
  for (final p in pts) {
    cb = cb + p;
  }
  cb = cb * (1.0 / pts.length);

  // Symmetric normal matrix, packed [a00,a01,a02,a11,a12,a22].
  final a = List<double>.filled(6, 0);
  var b1 = Vec3.zero, b2 = Vec3.zero;

  for (var i = 0; i < pts.length; i++) {
    final p = pts[i] - cb;
    final ox = obs[i].dx - pbx, oy = obs[i].dy - pby;

    a[0] += p.x * p.x;
    a[1] += p.x * p.y;
    a[2] += p.x * p.z;
    a[3] += p.y * p.y;
    a[4] += p.y * p.z;
    a[5] += p.z * p.z;

    b1 = b1 + p * ox;
    b2 = b2 + p * oy;
  }

  // Facial landmarks are nearly planar in Z, which leaves the depth column
  // poorly conditioned; without this ridge the fit twitches on frontal faces.
  final ridge = (a[0] + a[3] + a[5]) * 2e-4;
  a[0] += ridge;
  a[3] += ridge;
  a[5] += ridge;

  final r1 = _solveSym3(a, b1);
  final r2 = _solveSym3(a, b2);
  if (r1 == null || r2 == null) return null;

  final s = (r1.length + r2.length) * 0.5;
  if (!s.isFinite || s < 1e-4) return null;

  // Gram-Schmidt, then the third row is forced by right-handedness — there is
  // no sign freedom left once we insist on a proper rotation.
  final e0 = r1.normalized;
  final e1 = (r2 - e0 * r2.dot(e0)).normalized;
  final e2 = e0.cross(e1);

  final shift = Vec3(e0.dot(cb - _centroid), e1.dot(cb - _centroid),
          e2.dot(cb - _centroid)) *
      s;

  return LandmarkPose(
      [e0, e1, e2], s, Offset(pbx - shift.x, pby - shift.y));
}

Vec3? _solveSym3(List<double> a, Vec3 b) {
  final a00 = a[0], a01 = a[1], a02 = a[2], a11 = a[3], a12 = a[4], a22 = a[5];

  final c00 = a11 * a22 - a12 * a12;
  final c01 = a02 * a12 - a01 * a22;
  final c02 = a01 * a12 - a02 * a11;

  final det = a00 * c00 + a01 * c01 + a02 * c02;
  if (det.abs() < 1e-9) return null;

  final c11 = a00 * a22 - a02 * a02;
  final c12 = a02 * a01 - a00 * a12;
  final c22 = a00 * a11 - a01 * a01;

  final inv = 1.0 / det;
  return Vec3(
    (c00 * b.x + c01 * b.y + c02 * b.z) * inv,
    (c01 * b.x + c11 * b.y + c12 * b.z) * inv,
    (c02 * b.x + c12 * b.y + c22 * b.z) * inv,
  );
}

/// Turns landmarks into the tracking state the filter consumes.
///
/// [halfTanFovX] must come from the same camera the renderer uses
/// ([JeelizFaceFilterHelper.halfTanFovX]). The inversion below assumes the
/// render target and the video share an aspect ratio, which is how
/// [JeelizGlassesView] configures things — `scaleW` is then 1 and the camera's
/// view offset is a no-op, so canvas NDC and video NDC coincide.
class LandmarkDetectStateAdapter {
  LandmarkDetectStateAdapter({
    this.calibration = const JeelizCubeCalibration(),
    this.pivotOffsetYZ = const [0.2, 0.6],
    this.smoothing = 0.45,
    this.holdFrames = 6,
  });

  /// Inner-lip gap, in canonical millimetres, that reads as fully closed and
  /// fully open. The gap is measured in pixels and divided by the solved pose
  /// scale, so these are absolute face measurements and do not change with how
  /// near the camera the user sits.
  static const double kMouthClosedMm = 3.0;
  static const double kMouthOpenMm = 38.0;

  final JeelizCubeCalibration calibration;

  /// Must match [JeelizHelperSettings.pivotOffsetYZ] on the helper this feeds,
  /// because the conversion inverts the pivot displacement that `update_poses`
  /// applies. [JeelizGlassesController] keeps the two in step for you.
  final List<double> pivotOffsetYZ;

  /// 1.0 disables smoothing, lower is heavier (and laggier). Raw per-frame POS
  /// is accurate but jitters at the sub-degree level, which reads as the
  /// temples buzzing.
  final double smoothing;

  /// Keep reporting the last state for this many frames after tracking drops,
  /// so one missed detection does not blink the glasses out.
  final int holdFrames;

  DetectState? _prev;
  int _missed = 0;

  void reset() {
    _prev = null;
    _missed = 0;
  }

  /// [camera] must be the one the renderer draws with, already configured by
  /// [JeelizFaceFilterHelper.updateCamera].
  DetectState convert(
    List<Offset>? normalizedLandmarks,
    Size imageSize,
    PerspectiveCamera camera,
  ) {
    final raw = _solve(normalizedLandmarks, imageSize, camera);

    if (raw == null) {
      final prev = _prev;
      if (prev != null && ++_missed <= holdFrames) return prev;
      _prev = null;
      return DetectState.lost;
    }

    _missed = 0;
    final prev = _prev;
    _prev = prev == null ? raw : prev.lerpTo(raw, smoothing);
    return _prev!;
  }

  /// Mouth opening, 0..1, from the inner-lip landmarks (13 upper, 14 lower).
  ///
  /// Jeeliz gets this from a network whose raw output the tiger demo remaps
  /// with `(expressions[0] - 0.2) * 5` — that constant is a property of *its*
  /// network, not a definition of mouth opening. This measures the gap
  /// directly and normalises it against the solved face scale, so what comes
  /// out is already the 0..1 the demo's remap was trying to produce, and the
  /// filter applies no further curve.
  double _mouthOpening(
      List<Offset> lm, double imgW, double imgH, double scale) {
    const upper = 13, lower = 14;
    if (lm.length <= lower || scale < 1e-6) return 0;

    final a = lm[upper], b = lm[lower];
    if (a.dx.isNaN || b.dx.isNaN) return 0;

    final dx = (a.dx - b.dx) * imgW;
    final dy = (a.dy - b.dy) * imgH;
    final gapMm = math.sqrt(dx * dx + dy * dy) / scale;

    return clampd(
        (gapMm - kMouthClosedMm) / (kMouthOpenMm - kMouthClosedMm), 0, 1);
  }

  DetectState? _solve(
      List<Offset>? lm, Size imageSize, PerspectiveCamera camera) {
    if (lm == null || lm.isEmpty) return null;
    final aspect = camera.aspect;
    if (aspect <= 1e-6) return null;

    // Two different horizontal half-tangents, and the difference is not a
    // rounding error — it is ~7% at a phone's portrait aspect ratio.
    //
    // `update_poses` uses tan(aspect · fov / 2): it scales the *angle* by the
    // aspect ratio. The projection matrix, built from `top = near·tan(fov/2)`
    // and `width = aspect · height`, uses aspect · tan(fov / 2). Those agree
    // only for small angles. The demo's asset scales were tuned by eye on top
    // of that mismatch, so the port has to keep it.
    //
    // Hence: invert `update_poses` with Jeeliz's value, but work out where the
    // head has to *be* with the real one.
    final jeelizHalfTanX = math.tan(aspect * camera.fov * math.pi / 360);
    final trueHalfTanX = aspect * math.tan(camera.fov * math.pi / 360);
    if (jeelizHalfTanX <= 1e-6 || trueHalfTanX <= 1e-6) return null;

    final imgW = imageSize.width, imgH = imageSize.height;
    final pose = solveLandmarkPose(lm, imgW, imgH);
    if (pose == null) return null;

    // --- rotation ------------------------------------------------------
    // POS rows are (image right, image down, into screen). three.js wants
    // (right, up, towards viewer), so negate the last two rows. That basis
    // change has determinant +1, so the result is still a proper rotation.
    final m0 = pose.rows[0];
    final m1 = -pose.rows[1];
    final m2 = -pose.rows[2];

    // The face's +Z must come towards the lens. If it does not, the fit has
    // collapsed (near-degenerate landmarks) and reporting it would draw the
    // glasses backwards — drop the frame instead and let the hold window
    // cover the gap.
    if (m2.z <= 0) return null;

    // Euler ZYX from the rotation: rows above are m[row], columns are .x/.y/.z.
    final ry = math.asin(clampd(-m2.x, -1, 1));
    double rx, rz;
    if (math.cos(ry).abs() > 1e-4) {
      rx = math.atan2(m2.y, m2.z);
      rz = math.atan2(m1.x, m0.x);
    } else {
      // Gimbal lock (head fully in profile): roll is unrecoverable, pin it.
      rx = math.atan2(-m1.z, m1.y);
      rz = 0;
    }

    // --- place the cube in view space ------------------------------------
    // POS is a *weak-perspective* fit: its single scale is the one that best
    // explains all the landmarks at once, which under a real pinhole camera
    // corresponds to the depth of their centroid. So anchor on the centroid,
    // not on the cube's own origin — anchoring at the wrong plane leaves the
    // glasses correctly placed but a few percent too large, which reads as a
    // face that has grown into someone else's spectacles.
    //
    // A feature of size L at depth d covers L/(2·d·halfTanFovX) of the frame
    // width, and one cube unit is `unitMm · scale` pixels, so:
    final pxPerUnit = calibration.unitMm * pose.scale;
    if (pxPerUnit <= 1e-6) return null;
    final dCentroid = imgW / (2 * trueHalfTanX * pxPerUnit);
    if (!dCentroid.isFinite || dCentroid <= 0.51) return null;

    // Where the centroid sits, in view space, from its known pixel position.
    final ndcX = (pose.originPx.dx / imgW) * 2 - 1;
    final ndcY = 1 - (pose.originPx.dy / imgH) * 2;
    final cvx = ndcX * dCentroid * trueHalfTanX;
    final cvy = ndcY * dCentroid * trueHalfTanX / aspect;

    // --- invert update_poses ---------------------------------------------
    // update_poses builds the face object's origin as
    //
    //     O = R·q + T,   q = (-sin rz·p0, -cos rz·p0, -p1)
    //                    T = (xv, yv + p0, zv + p1)
    //
    // so the object does not sit at the cube centre once the head is rotated —
    // it swings about a pivot. The glasses hang off O, so solve for T (and
    // hence the cube centre) with that displacement included, rather than
    // pretending O is the centre.
    final p0 = pivotOffsetYZ[0], p1 = pivotOffsetYZ[1];
    final q = Vec3(-math.sin(rz) * p0, -math.cos(rz) * p0, -p1);

    // Centroid offset from the object origin, in cube units.
    final off = (_centroid - calibration.origin) * (1.0 / calibration.unitMm);
    final d = q + off;
    final rdx = m0.dot(d), rdy = m1.dot(d), rdz = m2.dot(d);

    final tx = cvx - rdx;
    final ty = cvy - rdy;
    final tz = -dCentroid - rdz;

    final xv = tx;
    final yv = ty - p0;
    final zv = tz - p1;

    final dist = -zv;
    if (!dist.isFinite || dist <= 0.51) return null;

    // update_poses derives that distance as `1/(2·s·halfTanFovX) + 0.5`
    // (centre of the cube = front face + half an edge).
    final s = 1 / (2 * jeelizHalfTanX * (dist - 0.5));
    if (!s.isFinite || s <= 0 || s > 4) return null;

    final x = xv / (dist * jeelizHalfTanX);
    final y = yv * aspect / (dist * jeelizHalfTanX);
    if (!x.isFinite || !y.isFinite) return null;

    return DetectState(
      detected: 1,
      x: x,
      y: y,
      s: s,
      rx: rx,
      ry: ry,
      rz: rz,
      expressions: [_mouthOpening(lm, imgW, imgH, pose.scale)],
    );
  }
}
