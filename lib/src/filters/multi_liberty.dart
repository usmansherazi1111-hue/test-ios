// Port of demos/threejs/multiLiberty — the Statue of Liberty, on every face
// in frame at once.
//
// This is the first ported demo that is genuinely **multi-face**: it sets
// `maxFacesDetected: 4` and clones its two meshes into every one of
// `threeStuffs.faceObjects`. So it is also the demo that made the controller
// grow per-slot tracking — see `JeelizFilterController.maxFaces`.
//
// Two details worth knowing:
//
//   * Both meshes are run through `JeelizThreeHelper.sortFaces(geom, 'z',
//     true)` before use, which reorders the index buffer by triangle depth so
//     the transparent statue composites sensibly. That helper had never been
//     ported; it is `sortGeometryFaces` now.
//   * `premultipliedAlpha: true` on the statue looks like it should change the
//     blend, and does not. three's `<premultiplied_alpha_fragment>` multiplies
//     rgb by alpha in the shader and then blends `ONE, ONE_MINUS_SRC_ALPHA` —
//     which is `src·a + dst·(1-a)`, exactly what plain `SRC_ALPHA,
//     ONE_MINUS_SRC_ALPHA` gives without the pre-multiply. Same picture.
//
// The face mask underneath is the interesting one: `CustomBlending` with
// `SrcColorFactor`/`OneFactor`, so it adds the *square* of its own colour onto
// whatever is behind. That is what tints the wearer's face oxidised-bronze
// without flattening it into a decal.

import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/material.dart' show BlendMode, MaterialSide;
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'liberty';

class MultiLibertyFilter extends JeelizFilter {
  MultiLibertyFilter({this.alphaMapWidth = 512});

  final int alphaMapWidth;

  /// `0xadd7bf` — cyan oxidised bronze.
  static const Vec3 kStatueColor =
      Vec3(0xad / 255, 0xd7 / 255, 0xbf / 255);

  /// `0x5da0a0` — the same bronze, pushed darker for the face tint.
  static const Vec3 kFaceColor = Vec3(0x5d / 255, 0xa0 / 255, 0xa0 / 255);

  BufferGeometry? _statueGeom;
  BufferGeometry? _maskGeom;
  LambertMaterial? _statueMat;
  BasicColorMaterial? _maskMat;

  final List<Object3D> _attached = [];

  @override
  ui.Image? get foreground => null;

  @override
  Future<void> load() async {
    final statue = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/liberty.json'));
    final mask = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/libertyFaceMask.json'));

    // `JeelizThreeHelper.sortFaces(geometry, 'z', true)` on both.
    sortGeometryFaces(statue, SortAxis.z, inverted: true);
    sortGeometryFaces(mask, SortAxis.z, inverted: true);

    _statueGeom = statue;
    _maskGeom = mask;

    _statueMat = LambertMaterial(
      color: kStatueColor,
      alphaMap: await Texture2D.decode(
          await loadJeelizAssetUint8List(
              '$_kAssetDir/libertyAlphaMapSoft512.png'),
          maxWidth: alphaMapWidth),
      transparent: true,
    );

    _maskMat = BasicColorMaterial(
      color: kFaceColor,
      transparent: true,
      side: MaterialSide.double,
      blend: BlendMode.srcColorAdd,
    );
  }

  /// `add_faceMesh` — the same transform, cloned into every tracked face.
  ///
  /// three's `.clone()` shares geometry and material between clones, and so do
  /// these: 15,932 triangles are uploaded once no matter how many faces are on
  /// screen.
  @override
  void attach(JeelizFaceFilterHelper helper) {
    for (final faceObject in helper.faceObjects) {
      final statue = Mesh(_statueGeom!, _statueMat!, name: 'liberty')
        ..renderOrder = 2;
      final mask = Mesh(_maskGeom!, _maskMat!, name: 'libertyFaceMask')
        ..renderOrder = 1;

      for (final m in [statue, mask]) {
        m
          ..scale = const Vec3(0.37, 0.37, 0.37)
          ..position = const Vec3(0, 0.25, 0.5);
        faceObject.add(m);
        _attached.add(m);
      }
    }

    helper.scene.add(AmbientLight(color: const Vec3(1, 1, 1), intensity: 0.5));
    helper.scene.add(
      DirectionalLight(
        color: const Vec3(1, 1, 0xee / 255),
        intensity: 0.7,
      )..position = const Vec3(0, 0.05, 1),
    );
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    for (final m in _attached) {
      m.parent?.remove(m);
    }
    _attached.clear();
  }

  @override
  void update(DetectState state, double dt) {
    // Nothing per-frame: every mesh is parented to a face object, and the
    // helper has already posed those from the tracking state.
  }
}
