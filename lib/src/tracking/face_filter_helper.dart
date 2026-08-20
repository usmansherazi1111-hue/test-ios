// Port of helpers/JeelizThreeHelper.js.
//
// Everything that made that file three.js-specific (the WebGL context
// handover, the video-texture quad, the two-canvas mode, the DOM resize
// listener) is gone: in Flutter the camera preview is a widget underneath and
// the overlay composites on top. What remains — and what is reproduced line
// for line — is `update_poses`, `detect`, `create_camera` and `update_camera`.
// That maths is the filter; the rest was plumbing.

import 'dart:math' as math;

import '../core/scene.dart';
import '../math/vec_mat.dart';
import 'detect_state.dart';

class JeelizHelperSettings {
  const JeelizHelperSettings({
    this.rotationOffsetX = 0.0,
    this.pivotOffsetYZ = const [0.2, 0.6],
    this.detectionThreshold = 0.8,
    this.detectionHysteresis = 0.02,
    this.cameraMinVideoDimFov = 35.0,
  });

  /// Negative makes the filter look upward. Radians.
  final double rotationOffsetX;

  /// Y and Z distance between the centre of the unit cube and the pivot the
  /// head appears to rotate about.
  final List<double> pivotOffsetYZ;

  /// Lower is more sensitive. The hysteresis band stops a face hovering at the
  /// threshold from flickering in and out.
  final double detectionThreshold;
  final double detectionHysteresis;

  /// Vertical field of view, in degrees, for the *smallest* video dimension.
  final double cameraMinVideoDimFov;
}

/// Signature of the original's `detect_callback(faceIndex, isDetected)`.
typedef DetectCallback = void Function(int faceIndex, bool isDetected);

class JeelizFaceFilterHelper {
  JeelizFaceFilterHelper({
    this.maxFacesDetected = 1,
    this.settings = const JeelizHelperSettings(),
    this.onDetect,
  }) {
    for (var i = 0; i < maxFacesDetected; i++) {
      final o = Object3D(name: 'face$i')..visible = false;
      _faceObjects.add(o);
      scene.add(o);
    }
  }

  final int maxFacesDetected;
  JeelizHelperSettings settings;
  DetectCallback? onDetect;

  final Scene scene = Scene();
  final List<Object3D> _faceObjects = [];

  /// The node a filter parents its content to. Mirrors the `faceObject` /
  /// `faceObjects` split in the original's return value.
  Object3D get faceObject => _faceObjects.first;
  List<Object3D> get faceObjects => List.unmodifiable(_faceObjects);

  bool get isDetected => _faceObjects.any((o) => o.visible);

  // Set by [updateCamera]; used by [updatePoses].
  double _scaleW = 1.0;
  double _canvasAspectRatio = 1.0;

  /// `create_camera()`. The fov and aspect are placeholders until
  /// [updateCamera] runs, exactly as in the original.
  PerspectiveCamera createCamera({double zNear = 0.1, double zFar = 100}) {
    final camera = PerspectiveCamera(fov: 1, aspect: 1, near: zNear, far: zFar);
    return camera;
  }

  /// `update_camera()`.
  ///
  /// [canvasSize] is the render target, [videoSize] the camera frame. When
  /// they share an aspect ratio — which is how [JeelizGlassesView] sets things
  /// up, letting Flutter do the cover-fit — the view offset degenerates to a
  /// no-op and `scaleW` to 1. The general path is kept because a filter that
  /// renders into a differently-shaped canvas needs it to stay aligned.
  void updateCamera(
    PerspectiveCamera camera, {
    required double canvasWidth,
    required double canvasHeight,
    required double videoWidth,
    required double videoHeight,
  }) {
    _canvasAspectRatio = canvasWidth / canvasHeight;

    final videoAspectRatio = videoWidth / videoHeight;
    final fovFactor = videoHeight > videoWidth ? (1.0 / videoAspectRatio) : 1.0;
    final fov = settings.cameraMinVideoDimFov * fovFactor;

    final scale = _canvasAspectRatio > videoAspectRatio
        ? canvasWidth / videoWidth // crop top and bottom
        : canvasHeight / videoHeight; // crop left and right

    final cvws = videoWidth * scale, cvhs = videoHeight * scale;
    final offsetX = (cvws - canvasWidth) / 2.0;
    final offsetY = (cvhs - canvasHeight) / 2.0;
    _scaleW = canvasWidth / cvws;

    camera.aspect = _canvasAspectRatio;
    camera.fov = fov;
    camera.setViewOffset(cvws, cvhs, offsetX, offsetY, canvasWidth, canvasHeight);
    camera.updateProjectionMatrix();
  }

  /// tan(horizontal FoV / 2), which several callers need to relate a detection
  /// window width to a depth.
  double halfTanFovX(PerspectiveCamera camera) =>
      math.tan(camera.aspect * camera.fov * math.pi / 360);

  double get scaleW => _scaleW;

  /// `detect()` — visibility with hysteresis, firing [onDetect] on transitions.
  void detect(List<DetectState> ds) {
    for (var i = 0; i < _faceObjects.length; i++) {
      if (i >= ds.length) continue;
      final o = _faceObjects[i];
      final d = ds[i].detected;
      if (o.visible &&
          d < settings.detectionThreshold - settings.detectionHysteresis) {
        onDetect?.call(i, false);
        o.visible = false;
      } else if (!o.visible &&
          d > settings.detectionThreshold + settings.detectionHysteresis) {
        onDetect?.call(i, true);
        o.visible = true;
      }
    }
  }

  /// `update_poses()`, transcribed.
  void updatePoses(List<DetectState> ds, PerspectiveCamera camera) {
    final halfTanFOVX = halfTanFovX(camera);
    final p0 = settings.pivotOffsetYZ[0];
    final p1 = settings.pivotOffsetYZ[1];

    for (var i = 0; i < _faceObjects.length; i++) {
      final o = _faceObjects[i];
      if (!o.visible || i >= ds.length) continue;
      final d = ds[i];

      final cz = math.cos(d.rz), sz = math.sin(d.rz);

      // Relative width of the detection window (1 -> the whole canvas).
      final w = d.s * _scaleW;

      // Distance from the camera to the front face of the unit cube, then to
      // its centre.
      final dFront = 1 / (2 * w * halfTanFOVX);
      final dist = dFront + 0.5;

      final xv = d.x * _scaleW;
      final yv = d.y * _scaleW;

      // Centre of the cube in view coordinates. Z is negative because the
      // camera looks down -Z.
      final z = -dist;
      final x = xv * dist * halfTanFOVX;
      final y = yv * dist * halfTanFOVX / _canvasAspectRatio;

      // Position before the pivot is applied...
      var pos = Vec3(-sz * p0, -cz * p0, -p1);

      // ...then rotate, which swings that offset about the pivot...
      o.rotation = Euler(
          d.rx + settings.rotationOffsetX, d.ry, d.rz, EulerOrder.zyx);
      pos = pos.applyEuler(o.rotation);

      // ...and finally translate into place.
      o.position = pos + Vec3(x, y + p0, z + p1);
    }
  }

  /// `render()` minus the actual draw call — apply tracking to the scene, then
  /// let the caller hand [scene] to a renderer.
  void update(List<DetectState> ds, PerspectiveCamera camera) {
    detect(ds);
    updatePoses(ds, camera);
  }
}
