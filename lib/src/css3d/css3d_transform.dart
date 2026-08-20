// Port of demos/CSS3D/comedy-glasses.
//
// This one is a different animal from every other port here. There is no
// three.js scene, no mesh and no renderer: the filter is a single `div` with a
// background image, placed by a CSS `matrix3d()`. So it does not touch the
// software rasteriser at all — it produces a matrix for a Flutter `Transform`,
// which is the exact analogue of what CSS does with that matrix.
//
// That makes it the cheapest possible filter and the sharpest: the image is
// composited by the GPU at native resolution rather than sampled through a CPU
// rasteriser. For a flat sprite — glasses, a moustache, a hat — this is the
// right tool, and it is worth knowing the library can do it.
//
// The demo also carries its **own** pose maths, which is *not*
// `JeelizThreeHelper.update_poses`. Three differences, all deliberate:
//
//   * `tanFOV = tan(aspect * fov * PI/360)` and `D = 1/(2*W*tanFOV)`, where D
//     is the distance to the *front face*; the cube centre is then `-D - 0.5`.
//     The three.js helper folds that half-edge in earlier.
//   * The Euler is built `(-rx - offset, -ry, rz)` in **XYZ** order, not
//     `(rx, ry, rz)` in ZYX. The sign flips are not arbitrary: `-rx` converts a
//     Y-up view space into CSS's Y-**down** screen space, and `-ry` mirrors the
//     yaw to match the horizontally-flipped preview. `rz` flips twice and so
//     comes out unchanged. Flutter's widget space is also Y-down, so the same
//     conversion carries over untouched.
//   * Position is likewise `(-x, -y + ..., z + ...)` — mirror, then Y-down —
//     and is finally scaled into **pixels** by `(width, height, perspective/2)`.
//
// One detail worth not "fixing": `perspectivePx` divides by
// `tan(fov * PI/180)`, i.e. the *whole* field of view rather than half of it.
// Reproduced as written; it is what makes the numbers come out right.

import 'dart:math' as math;

import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';

/// `SETTINGS` from the demo's main.js.
class Css3dSettings {
  const Css3dSettings({
    this.rotationOffsetX = 0.0,
    this.cameraFov = 40.0,
    this.pivotOffsetYZ = const [-0.15, -0.15],
    this.detectionThreshold = 0.75,
    this.detectionHysteresis = 0.05,
    this.mouthOpeningThreshold = 0.5,
    this.mouthOpeningHysteresis = 0.05,
    this.scale = const [1.3, 1.3],
    this.positionOffset = const [0.0, 0.1, -0.2],
    this.mirror = true,
  });

  /// Negative looks upward. Radians.
  final double rotationOffsetX;

  /// Degrees. Used *whole* in the perspective calculation and *halved* in
  /// `tanFOV`, exactly as the demo does.
  final double cameraFov;

  /// Rotation pivot along Y and Z.
  final List<double> pivotOffsetYZ;

  final double detectionThreshold;
  final double detectionHysteresis;

  /// The demo toggles `mouthOpened` / `mouthClosed` CSS classes at these
  /// thresholds. Both rules are **empty** in its stylesheet, so nothing moves —
  /// they are a hook for whoever styles the element. [Css3dPose.isMouthOpen]
  /// carries the same signal here.
  final double mouthOpeningThreshold;
  final double mouthOpeningHysteresis;

  /// Scale of the element along its horizontal and vertical axis.
  final List<double> scale;

  /// A 3D position offset applied to the element.
  final List<double> positionOffset;

  /// Whether the preview underneath is mirrored, which is what the `-x` / `-ry`
  /// sign flips compensate for. The demo's canvas carries
  /// `transform: rotateY(180deg)`, so this is true there.
  final bool mirror;

  Css3dSettings copyWith({List<double>? scale, List<double>? positionOffset}) =>
      Css3dSettings(
        rotationOffsetX: rotationOffsetX,
        cameraFov: cameraFov,
        pivotOffsetYZ: pivotOffsetYZ,
        detectionThreshold: detectionThreshold,
        detectionHysteresis: detectionHysteresis,
        mouthOpeningThreshold: mouthOpeningThreshold,
        mouthOpeningHysteresis: mouthOpeningHysteresis,
        scale: scale ?? this.scale,
        positionOffset: positionOffset ?? this.positionOffset,
        mirror: mirror,
      );
}

/// The result of one frame of CSS3D placement.
class Css3dPose {
  Css3dPose({
    required this.matrix,
    required this.perspective,
    required this.visible,
    required this.isMouthOpen,
  });

  /// Element-local to screen, about the element's own centre. Already includes
  /// the CSS `perspective()` term, so it can go straight into a `Transform`.
  final Mat4 matrix;

  /// The perspective distance in pixels.
  final double perspective;

  /// False when tracking is lost — the demo sets `display: none`.
  final bool visible;

  final bool isMouthOpen;
}

/// Tracks detection and mouth opening with hysteresis, and turns a
/// [DetectState] into a CSS3D transform.
///
/// Stateful only because both thresholds latch, exactly as the demo's
/// `ISDETECTED` / `ISMOUTHOPENED` globals do.
class Css3dPlacer {
  Css3dPlacer({this.settings = const Css3dSettings()});

  Css3dSettings settings;

  bool _isDetected = false;
  bool _isMouthOpen = false;

  bool get isDetected => _isDetected;
  bool get isMouthOpen => _isMouthOpen;

  /// Clears the latches, e.g. when the camera restarts.
  void reset() {
    _isDetected = false;
    _isMouthOpen = false;
  }

  /// [width] and [height] are the element's pixel size. The demo makes its div
  /// exactly canvas-sized and lets `background-size: cover` stretch the image
  /// over it, so pass the size of the area the overlay covers.
  Css3dPose place(DetectState state, double width, double height) {
    final s = settings;

    // Detection latch with hysteresis.
    if (_isDetected &&
        state.detected < s.detectionThreshold - s.detectionHysteresis) {
      _isDetected = false;
    } else if (!_isDetected &&
        state.detected > s.detectionThreshold + s.detectionHysteresis) {
      _isDetected = true;
    }

    // Mouth latch, same shape.
    final mouth = state.mouthOpening;
    if (_isMouthOpen &&
        mouth < s.mouthOpeningThreshold - s.mouthOpeningHysteresis) {
      _isMouthOpen = false;
    } else if (!_isMouthOpen &&
        mouth > s.mouthOpeningThreshold + s.mouthOpeningHysteresis) {
      _isMouthOpen = true;
    }

    if (!_isDetected || width <= 0 || height <= 0) {
      return Css3dPose(
        matrix: Mat4.identity(),
        perspective: 0,
        visible: false,
        isMouthOpen: _isMouthOpen,
      );
    }

    final aspect = width / height;
    final w2 = width / 2, h2 = height / 2;

    // `Math.round(Math.pow(w2*w2 + h2*h2, 0.5) / Math.tan(fov * PI / 180))`.
    // The whole FOV, not half of it — as written.
    final perspective =
        (math.sqrt(w2 * w2 + h2 * h2) / math.tan(s.cameraFov * math.pi / 180))
            .roundToDouble();

    // tan(FOV/2), with the aspect folded into the angle — the same
    // approximation the three.js helper makes.
    final tanFov = math.tan(aspect * s.cameraFov * math.pi / 360);

    final w = state.s;
    if (w <= 1e-6 || tanFov <= 1e-9 || perspective <= 0) {
      return Css3dPose(
        matrix: Mat4.identity(),
        perspective: perspective,
        visible: false,
        isMouthOpen: _isMouthOpen,
      );
    }

    // Distance to the *front face* of the unit cube, then to its centre.
    final d = 1 / (2 * w * tanFov);
    final z = -d - 0.5;
    final x = state.x * d * tanFov;
    final y = state.y * d * tanFov / aspect;

    // Mirroring flips only the horizontal terms; the Y negation is the Y-down
    // conversion and applies either way.
    final mx = s.mirror ? -1.0 : 1.0;

    final euler = Euler(
      -state.rx - s.rotationOffsetX,
      mx * state.ry,
      state.rz,
      EulerOrder.xyz,
    );

    var position = Vec3(
      mx * x,
      -y + s.pivotOffsetYZ[0],
      z + s.pivotOffsetYZ[1],
    );

    // pivotOffset0 = (0, -pivotY, -pivotZ), minus the position offset, rotated
    // with the head — so the element swings about that pivot rather than about
    // its own centre.
    final pivotOffset = Vec3(0, -s.pivotOffsetYZ[0], -s.pivotOffsetYZ[1]) -
        Vec3(s.positionOffset[0], s.positionOffset[1], s.positionOffset[2]);

    position = position + pivotOffset.applyEuler(euler);

    // Into pixels. x scales by the full width and y by the full height, not
    // their halves — that is what the original does, and the perspective divide
    // is what brings it back to a sane size on screen.
    position = Vec3(
      position.x * width,
      position.y * height,
      position.z * perspective / 2.0,
    );

    // makeRotationFromEuler, then setPosition, then scale — in that order, so
    // the scale lands in the element's own rotated frame.
    final m = Mat4.rotationFromEuler(euler);
    m.m[12] = position.x;
    m.m[13] = position.y;
    m.m[14] = position.z;
    _scaleInPlace(m, s.scale[0], s.scale[1], 1.0);

    // CSS `transform: perspective(P) matrix3d(M)` is P·M, P being the identity
    // with -1/P at row 3, column 2. Flutter's Transform takes the product.
    return Css3dPose(
      matrix: perspectiveMatrix(perspective) * m,
      perspective: perspective,
      visible: true,
      isMouthOpen: _isMouthOpen,
    );
  }

  /// CSS's `perspective(p)` as a matrix.
  static Mat4 perspectiveMatrix(double p) {
    final m = Mat4.identity();
    // Column-major storage: index 11 is row 3, column 2.
    if (p > 0) m.m[11] = -1.0 / p;
    return m;
  }

  /// `three.Matrix4.scale(v)` — scales each basis column in place.
  static void _scaleInPlace(Mat4 m, double sx, double sy, double sz) {
    final e = m.m;
    for (var i = 0; i < 4; i++) {
      e[i] *= sx;
      e[4 + i] *= sy;
      e[8 + i] *= sz;
    }
  }
}
