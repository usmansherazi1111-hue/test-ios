// Port of demos/threejs/glassesVTO — both JeelizThreeGlassesCreator.js and
// the init_threeScene() half of main.js.
//
// Every constant below is the demo's, unchanged. If the glasses ever sit
// wrong on the face, the bug is in the tracking adapter or the calibration,
// not here — this file is meant to stay a transcription.

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

/// Path under whichever assets root is live — see `core/assets.dart`, which
/// works out whether this package is the running app or a dependency of one.
const String _kAssetDir = 'glassesVTO';

/// Which frame model to use. The demo ships two exports of the same glasses;
/// main.js loads the bent-branch one because straight temples clip through the
/// side of the head as soon as it turns.
enum GlassesFrameModel { branchesBent, straight }

/// The loaded, ready-to-parent result of `JeelizThreeGlassesCreator(spec)`.
class GlassesAssets {
  const GlassesAssets({
    required this.glasses,
    required this.occluder,
    required this.framesMaterial,
    required this.lensesMaterial,
    required this.envMap,
  });

  /// Container holding the frames and lenses meshes, as the original returns.
  final Object3D glasses;

  /// Depth-only head mesh. Parent it to the same face object.
  final Mesh occluder;

  /// Exposed so a caller can retint or restyle at runtime — the JS demo hangs
  /// these on `window.debugMatFrames` / `window.debugMatLens` for the same
  /// reason.
  final FramesMaterial framesMaterial;
  final LensesMaterial lensesMaterial;

  final EquirectTexture envMap;
}

/// `JeelizThreeGlassesCreator(spec)`.
Future<GlassesAssets> createGlasses({
  GlassesFrameModel frameModel = GlassesFrameModel.branchesBent,
  int envMapWidth = 512,
}) async {
  final envMap = await EquirectTexture.decode(
      await loadJeelizAssetUint8List('$_kAssetDir/envMap.jpg'),
      maxWidth: envMapWidth);

  final frameAsset = switch (frameModel) {
    GlassesFrameModel.branchesBent => 'glassesFramesBranchesBent.json',
    GlassesFrameModel.straight => 'glassesFrames.json',
  };

  // The exports carry positions and indices only, so normals are computed on
  // load exactly as the JS does right after each BufferGeometryLoader call.
  final framesGeom = decodeBufferGeometry(
      await loadJeelizAssetString('$_kAssetDir/$frameAsset'));
  final lensesGeom = decodeBufferGeometry(
      await loadJeelizAssetString('$_kAssetDir/glassesLenses.json'));
  final occluderGeom = decodeBufferGeometry(
      await loadJeelizAssetString('$_kAssetDir/face.json'));

  final framesMat = FramesMaterial(envMap: envMap);
  final lensesMat = LensesMaterial(envMap: envMap);

  final glasses = Object3D(name: 'glasses')
    ..add(Mesh(framesGeom, framesMat, name: 'glassesFrames'))
    ..add(Mesh(lensesGeom, lensesMat, name: 'glassesLenses'));

  // `create_threejsOccluder`: renderOrder -1 so it lays down depth before
  // anything tests against it.
  final occluder = Mesh(occluderGeom, OccluderMaterial(), name: 'occluder')
    ..renderOrder = -1;

  return GlassesAssets(
    glasses: glasses,
    occluder: occluder,
    framesMaterial: framesMat,
    lensesMaterial: lensesMat,
    envMap: envMap,
  );
}

/// The glassesVTO filter, as a [JeelizFilter].
class GlassesFilter extends JeelizFilter {
  GlassesFilter({
    this.frameModel = GlassesFrameModel.branchesBent,
    this.envMapWidth = 512,
    this.dy = 0.07,
  });

  final GlassesFrameModel frameModel;
  final int envMapWidth;

  /// Vertical offset, `const dy = 0.07` in main.js.
  final double dy;

  GlassesAssets? assets;

  @override
  Future<void> load() async {
    assets =
        await createGlasses(frameModel: frameModel, envMapWidth: envMapWidth);
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final a = assets;
    if (a != null) buildGlassesScene(helper, a, dy: dy);
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final a = assets;
    if (a == null) return;
    helper.faceObject
      ..remove(a.occluder)
      ..remove(a.glasses);
  }
}

/// `init_threeScene(spec)` from main.js: parents the assets to the tracked
/// face object with the demo's offsets and scales.
///
/// ```js
/// const dy = 0.07;
/// r.occluder.rotation.set(0.3, 0, 0);
/// r.occluder.position.set(0, 0.03 + dy, -0.04);
/// r.occluder.scale.multiplyScalar(0.0084);
/// threeStuffs.faceObject.add(r.occluder);
///
/// threeGlasses.position.set(0, dy, 0.4);
/// threeGlasses.scale.multiplyScalar(0.006);
/// threeStuffs.faceObject.add(threeGlasses);
/// ```
void buildGlassesScene(
  JeelizFaceFilterHelper helper,
  GlassesAssets assets, {
  double dy = 0.07,
}) {
  assets.occluder
    ..rotation = const Euler(0.3, 0, 0)
    ..position = Vec3(0, 0.03 + dy, -0.04)
    ..scale = Vec3.one;
  assets.occluder.scaleUniform(0.0084);
  helper.faceObject.add(assets.occluder);

  assets.glasses
    ..position = Vec3(0, dy, 0.4)
    ..scale = Vec3.one;
  assets.glasses.scaleUniform(0.006);
  helper.faceObject.add(assets.glasses);
}
