// Port of demos/threejs/cloud — a rain cloud parked over the head.
//
// Three clouds sharing one geometry and one material, a point light flashing
// inside the biggest one as lightning, and three streams of falling rain.
//
// Two lines in the original are inert and reproduced as such:
//
//   * `CLOUDMESH2.quaternion._y = CLOUDMESH2.quaternion._y * 10` pokes a
//     quaternion's private field, bypassing three's change callback. The
//     quaternion is identity, so `_y` is 0 and 0 × 10 is still 0 — no rotation,
//     and no update even if there had been one. Same line again for cloud 3.
//   * `drop.png` ships with the demo and is never loaded; the rain is an
//     untextured white plane. It is not copied into this package.
//
// The clone chain is worth reading carefully, because the scales compound:
// cloud 1 is set to (0.4, 0.2, 0.4), then clouds 2 and 3 are cloned *from that*
// and scaled again, so their final scales are much smaller than the literals in
// the source suggest.

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/material.dart' show MaterialSide;
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';
import 'tiger.dart' show planeGeometry;

const String _kAssetDir = 'cloud';

class CloudFilter extends JeelizFilter {
  CloudFilter({
    this.dropsPerStream = 501,
    this.textureWidth = 512,
    this.showFrame = true,
  });

  /// `for (let i = 0; i <= 500; i++)` — so 501, three times over.
  ///
  /// Each drop is its own mesh in the original, and each costs a draw here.
  /// Lower it if the rain is too expensive on a slow device; the look degrades
  /// gracefully because the streams are randomised.
  final int dropsPerStream;

  final int textureWidth;
  final bool showFrame;

  Object3D? _group;
  PointLight? _lightning;
  ui.Image? _frame;

  final List<_Drop> _drops = [];
  final _Lightning _flash = _Lightning();
  final math.Random _rng = math.Random();

  @override
  ui.Image? get foreground => _frame;

  /// Lightning intensity, for tests and the HUD.
  double get lightningIntensity => _lightning?.intensity ?? 0;

  @override
  Future<void> load() async {
    final geom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/cloud.json'));

    // One material and one geometry for all three clouds, as `.clone()` gives.
    final cloudMat = PhongMaterial(
      map: await Texture2D.decode(
          await loadJeelizAssetUint8List('$_kAssetDir/cloud.png'),
          maxWidth: textureWidth),
      shininess: 2,
      specular: const Vec3(1, 1, 1),
      opacity: 0.7,
      transparent: true,
    );

    // cloud 1: scale ×0.4 then y ×0.5.
    final cloud1 = Mesh(geom, cloudMat, name: 'cloud1')
      ..scale = const Vec3(0.4, 0.2, 0.4)
      ..position = const Vec3(0, 0.85, 0)
      ..renderOrder = 10000;

    // cloud 2 clones cloud 1 — so it starts at (0.4, 0.2, 0.4) — then ×0.4,
    // then y ×0.9 and x ×0.7.
    final cloud2 = Mesh(geom, cloudMat, name: 'cloud2')
      ..scale = const Vec3(0.4 * 0.4 * 0.7, 0.2 * 0.4 * 0.9, 0.4 * 0.4)
      ..position = const Vec3(0.7, 0.99, 0)
      ..renderOrder = 10000;

    // cloud 3 likewise, then y ×1.3 and x ×1.2.
    final cloud3 = Mesh(geom, cloudMat, name: 'cloud3')
      ..scale = const Vec3(0.4 * 0.4 * 1.2, 0.2 * 0.4 * 1.3, 0.4 * 0.4)
      ..position = const Vec3(-0.25, 0.69, 0.1)
      ..renderOrder = 10000;

    // `new THREE.PointLight(0xffffff, 0, 100)` — starts dark, cutoff 100.
    _lightning = PointLight(
      color: const Vec3(1, 1, 1),
      intensity: 0,
      distance: 100,
    )..position = const Vec3(0, 0.15, -1);

    _buildRain();

    _group = Object3D(name: 'cloudGroup')
      ..add(cloud1)
      ..add(cloud2)
      ..add(cloud3)
      ..add(_lightning!);

    final rainRoot = Object3D(name: 'rain');
    for (final d in _drops) {
      rainRoot.add(d.mesh);
    }
    _group!.add(rainRoot);

    if (showFrame) {
      final bytes =
          await loadJeelizAssetUint8List('$_kAssetDir/frame_cloud.png');
      final codec = await ui.instantiateImageCodec(bytes);
      _frame = (await codec.getNextFrame()).image;
      codec.dispose();
    }
  }

  void _buildRain() {
    // `new THREE.PlaneGeometry(0.09, 0.7)`, then `scale.multiplyScalar(0.1)`.
    final dropGeom = planeGeometry(0.09, 0.7);
    final dropMat = BasicColorMaterial(
      color: const Vec3(1, 1, 1),
      opacity: 0.5,
      transparent: true,
      side: MaterialSide.double,
    );

    // Three streams, each seeded differently — the widest one under the main
    // cloud and two narrower ones under the smaller clouds.
    for (var i = 0; i < dropsPerStream; i++) {
      _addDrop(dropGeom, dropMat, i,
          x: _rng.nextDouble() * 1.4 - 0.7, y: 1.5, z: 0);
      _addDrop(dropGeom, dropMat, i,
          x: _rng.nextDouble() * 0.3 - 0.15 + 0.7, y: 1.19, z: 0);
      _addDrop(dropGeom, dropMat, i,
          x: _rng.nextDouble() * 0.4 - 0.2 - 0.3, y: 1.1, z: 0.02);
    }
  }

  void _addDrop(BufferGeometry geom, BasicColorMaterial mat, int index,
      {required double x, required double y, required double z}) {
    final mesh = Mesh(geom, mat, name: 'drop')
      ..position = Vec3(x, y, z)
      ..scale = const Vec3(0.1, 0.1, 0.1)
      ..renderOrder = 100000;
    _drops.add(_Drop(mesh, startY: y, delay: index * 0.015));
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    helper.faceObject.add(_group!);

    helper.scene.add(AmbientLight(color: const Vec3(1, 1, 1), intensity: 0.8));
    helper.scene.add(
      DirectionalLight(color: const Vec3(1, 1, 1))
        ..position = const Vec3(100, 1000, 100),
    );
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    if (_group != null) helper.faceObject.remove(_group!);
  }

  @override
  void update(DetectState state, double dt) {
    for (final d in _drops) {
      d.advance(dt);
    }

    final light = _lightning;
    if (light != null) {
      _flash.advance(dt);
      light.intensity = _flash.intensity;
      // Each strike moves along x, as `light.position.set(x, 0, z)` does.
      if (_flash.consumeReposition()) {
        light.position =
            Vec3(_rng.nextDouble() * 2 - 1, 0, light.position.z);
      }
    }
  }
}

/// One raindrop on a repeating fall.
///
/// The original is `TWEEN.Tween(position).to({y: -20}, 3000).delay(index*15)
/// .repeat(Infinity)`. TWEEN re-applies the delay on every repeat, so each drop
/// cycles with period `3000 + 15·index` ms and sits parked at its start height
/// for the delay part of that — which is what staggers the streams into looking
/// like rain rather than a falling wall.
class _Drop {
  _Drop(this.mesh, {required this.startY, required this.delay})
      : _x = mesh.position.x,
        _z = mesh.position.z;

  final Mesh mesh;
  final double startY;
  final double _x, _z;

  /// Seconds of wait before each fall.
  final double delay;

  static const double kFallSeconds = 3.0;
  static const double kEndY = -20.0;

  double _t = 0;

  void advance(double dt) {
    final period = delay + kFallSeconds;
    _t = (_t + dt) % period;

    if (_t < delay) {
      // Parked at the top, waiting its turn.
      mesh.position = Vec3(_x, startY, _z);
      return;
    }

    final k = ((_t - delay) / kFallSeconds).clamp(0.0, 1.0);
    mesh.position = Vec3(_x, startY + (kEndY - startY) * k, _z);
  }
}

/// The lightning flash.
///
/// `animate_pointLight` chains four tweens on the light's intensity —
/// 0→3 over 100ms, 3→0 over 50ms, 0→3 over 80ms, 3→0 over 50ms — then waits
/// 3000ms, moves along x, and starts over. A double flicker, not a single
/// flash.
class _Lightning {
  static const List<({double from, double to, double seconds})> _steps = [
    (from: 0, to: 3, seconds: 0.100),
    (from: 3, to: 0, seconds: 0.050),
    (from: 0, to: 3, seconds: 0.080),
    (from: 3, to: 0, seconds: 0.050),
  ];
  static const double kPauseSeconds = 3.0;

  int _step = 0;
  double _t = 0;
  bool _pausing = false;
  bool _needsReposition = false;

  double intensity = 0;

  /// True once per cycle, when the strike should move.
  bool consumeReposition() {
    if (!_needsReposition) return false;
    _needsReposition = false;
    return true;
  }

  void advance(double dt) {
    _t += dt;

    if (_pausing) {
      if (_t >= kPauseSeconds) {
        _t = 0;
        _pausing = false;
        _step = 0;
        _needsReposition = true;
      }
      intensity = 0;
      return;
    }

    final s = _steps[_step];
    if (_t >= s.seconds) {
      _t -= s.seconds;
      _step++;
      if (_step >= _steps.length) {
        _step = 0;
        _pausing = true;
        intensity = 0;
        return;
      }
    }

    final cur = _steps[_step];
    final k = (cur.seconds <= 0 ? 1.0 : _t / cur.seconds).clamp(0.0, 1.0);
    intensity = cur.from + (cur.to - cur.from) * k;
  }
}
