// Port of demos/threejs/casa_de_papel.
//
// The mask itself is the simplest filter of the three so far — one mesh, one
// Phong material — but it is the first to need a **normal map**, which is why
// the renderer grew a tangent frame for it.
//
// Two things in the original are worth knowing before reading the port,
// because both look like bugs otherwise:
//
//   * `emissiveMap: CasaDePapel_REFLECT.png` does nothing. three multiplies an
//     emissive map into `totalEmissiveRadiance`, which starts at the material's
//     `emissive` colour — default **black**. The map is wired up here for the
//     same reason, and is equally inert until you raise `emissive`.
//   * `reflectivity: 1` also does nothing: on MeshPhongMaterial it only has an
//     effect alongside an envMap, and there is none.
//
// Not ported: the `bella_ciao.mp3` soundtrack. Playing audio needs a plugin
// dependency, and this library deliberately has none — see [startHeist], which
// is the hook a host app drives its own audio from.

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

const String _kAssetDir = 'casaDePapel';

class CasaDePapelFilter extends JeelizFilter {
  CasaDePapelFilter({
    this.billCount = 40,
    this.textureWidth = 512,
    this.showFrame = true,
  });

  /// `for (let i = 0; i < 40; i++)` in the original.
  final int billCount;

  /// Decode width for the 1024² diffuse and normal maps.
  final int textureWidth;

  /// Whether to load `calque.png`, the full-screen frame the demo lays over
  /// everything with `renderOrder = 999`.
  final bool showFrame;

  Mesh? _mask;
  final List<_Bill> _bills = [];
  Object3D? _billsRoot;
  ui.Image? _frame;

  final math.Random _rng = math.Random();

  /// Base position of the mask, before [maskOffset].
  static const Vec3 _kMaskBasePosition = Vec3(0, -0.8, 0);

  /// User adjustment, in face-object units.
  ///
  /// The demo calls `addDragEventListener(maskMesh)` so the mask can be nudged
  /// onto the face by dragging. That helper is ~150 lines of DOM plumbing
  /// around one idea: move the mesh in its parent's XY plane. This is that
  /// idea; the host app supplies the gesture.
  Vec3 maskOffset = Vec3.zero;

  @override
  ui.Image? get foreground => _frame;

  @override
  Future<void> load() async {
    final geom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/casa_de_papel.json'));

    final diffuse = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/CasaDePapel_DIFFUSE.png'),
        maxWidth: textureWidth);
    final normal = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/CasaDePapel_NRM.png'),
        maxWidth: textureWidth);
    final reflect = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/CasaDePapel_REFLECT.png'),
        maxWidth: 256);

    _mask = Mesh(
      geom,
      PhongMaterial(
        map: diffuse,
        normalMap: normal,
        emissiveMap: reflect,
      ),
      name: 'casaDePapelMask',
    )
      // `scale.multiplyScalar(0.06)` then `scale.x = 0.07` — so the mask is
      // very slightly wider than it is deep or tall.
      ..scale = const Vec3(0.07, 0.06, 0.06)
      ..position = _kMaskBasePosition;

    await _buildBills();
    if (showFrame) {
      _frame = await _decodeImage('$_kAssetDir/calque.png');
    }
  }

  Future<void> _buildBills() async {
    final billTexture = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/billet_50.png'),
        maxWidth: 256);

    // One geometry and one material shared by all 40, as in the original.
    final geom = planeGeometry(0.4, 0.4);
    final mat = LambertMaterial(
      map: billTexture,
      side: MaterialSide.double,
      transparent: true,
    );

    for (var i = 0; i < billCount; i++) {
      final xRand = _rng.nextDouble() * 1 - 0.5;
      final zRand = (_rng.nextDouble() * 3 - 1.5) - 1.5;

      final mesh = Mesh(geom, mat, name: 'bill$i')
        ..renderOrder = 100
        ..visible = false
        ..position = Vec3(xRand, 3, zRand)
        // `scale.multiplyScalar(0.4)` then `scale.z = xRand * 10`. Z scale on
        // a flat plane changes nothing, but it is what the original does.
        ..scale = Vec3(0.4, 0.4, xRand * 10)
        ..rotation = Euler(0, xRand, zRand);

      _bills.add(_Bill(mesh,
          releaseAt: 0.230 * i,
          startPosition: mesh.position,
          startRotation: mesh.rotation));
    }
  }

  Future<ui.Image> _decodeImage(String relative) async {
    final bytes = await loadJeelizAssetUint8List(relative);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    helper.faceObject.add(_mask!);

    // The bills belong to the *scene*, not the face: they fall through world
    // space and keep falling whether or not a face is being tracked.
    final root = Object3D(name: 'bills');
    for (final b in _bills) {
      root.add(b.mesh);
    }
    helper.scene.add(root);
    _billsRoot = root;

    helper.scene.add(AmbientLight(color: const Vec3(1, 1, 1), intensity: 0.8));
    helper.scene.add(
      DirectionalLight(color: const Vec3(1, 1, 1), intensity: 0.5)
        ..position = const Vec3(100, 1000, 1000),
    );
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    if (_mask != null) helper.faceObject.remove(_mask!);
    if (_billsRoot != null) helper.scene.remove(_billsRoot!);
  }

  bool _running = false;
  double _elapsed = 0;
  double _accumulator = 0;

  /// Starts the money falling. The demo triggers this from its "play" button,
  /// alongside the soundtrack.
  void startHeist() {
    _running = true;
    _elapsed = 0;
  }

  /// Hides the bills and rewinds the release schedule.
  void reset() {
    _running = false;
    _elapsed = 0;
    _accumulator = 0;
    for (final b in _bills) {
      b.mesh.visible = false;
      b.reset();
    }
  }

  bool get isRunning => _running;

  /// The bill meshes, in release order. Exposed for inspection and testing —
  /// their motion is the one part of this filter with no static answer.
  List<Mesh> get bills =>
      List.unmodifiable(_bills.map((b) => b.mesh));

  @override
  void update(DetectState state, double dt) {
    _mask?.position = _kMaskBasePosition + maskOffset;
    if (!_running) return;

    _elapsed += dt;
    for (final b in _bills) {
      if (!b.mesh.visible && _elapsed >= b.releaseAt) b.mesh.visible = true;
    }

    // The original animates on `setInterval(..., 16)`, so its motion constants
    // are per-16ms-tick, not per-second. Stepping a fixed accumulator keeps
    // the money falling at the same speed regardless of what frame rate the
    // camera actually delivers.
    _accumulator += dt;
    var steps = 0;
    while (_accumulator >= _kTick && steps < _kMaxCatchUpSteps) {
      _accumulator -= _kTick;
      steps++;
      for (final b in _bills) {
        if (b.mesh.visible) b.tick();
      }
    }
    // Do not try to catch up an unbounded backlog after a stall.
    if (_accumulator > _kTick * _kMaxCatchUpSteps) _accumulator = 0;
  }

  static const double _kTick = 0.016;
  static const int _kMaxCatchUpSteps = 4;
}

/// One falling bill, plus the counter its horizontal sway is driven by.
class _Bill {
  _Bill(
    this.mesh, {
    required this.releaseAt,
    required this.startPosition,
    required this.startRotation,
  });

  final Mesh mesh;

  /// Seconds after [CasaDePapelFilter.startHeist] that this bill appears —
  /// `setTimeout(..., 230 * i)` in the original.
  final double releaseAt;

  final Vec3 startPosition;
  final Euler startRotation;

  double _count = 0;

  void reset() {
    _count = 0;
    mesh
      ..position = startPosition
      ..rotation = startRotation;
  }

  /// One 16ms step of `animate_bill`.
  void tick() {
    var p = mesh.position;
    if (p.y < -3) p = Vec3(p.x, 3, p.z);

    final sway = 0.005 * math.cos(math.pi / 40 * _count);
    final r = mesh.rotation;

    mesh
      ..position = Vec3(p.x + sway, p.y - 0.01, p.z)
      ..rotation = Euler(r.x + 0.03, r.y + sway, r.z + 0.02, r.order);

    _count += 0.9;
  }
}
