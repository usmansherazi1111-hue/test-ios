// Port of demos/threejs/luffys_hat_part1 and luffys_hat_part2.
//
// Two demos, one straw hat, and the second is the first done properly. Part 1
// puts a textured hat on your head and stops. Part 2 re-textures it, re-seats
// it, adds the low-poly face fill that hides your real hairline under the brim,
// moves the tracking pivot, makes the whole thing draggable, and frames the
// result. They are one filter here with a [LuffysHatPart] switch, because the
// difference between them is data.
//
// Part 1 carries three lines that do nothing, and they are worth naming because
// each looks load-bearing:
//
//  * `hatMesh.rotation.set(0, -40, 0)` — three's Euler takes **radians**. -40
//    radians is -40 + 7*2pi = 3.98 rad, about 228 degrees. Almost certainly a
//    typo for -40 degrees; reproduced anyway, because that is where the bow
//    actually sits in the demo.
//  * `hatMesh.side = THREE.DoubleSide` — `side` is a *material* property. Set
//    on the mesh it is an inert field assignment, so the hat stays front-faced.
//  * `new THREE.AmbientLight(0xFFFFFF, 0.8)` — the hat is
//    `MeshBasicMaterial`, which is unlit. Part 2 adds the same light and its
//    two materials are unlit and custom, so it is inert there too.

import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';
import 'rupy_helmet.dart' show HelmetFaceMaterial;

const String _kAssetDir = 'luffysHat';

/// Which of the two demos to run.
enum LuffysHatPart {
  /// `luffys_hat_part1` — the hat alone.
  part1,

  /// `luffys_hat_part2` — hat, face fill, moved pivot, drag, frame.
  part2,
}

class LuffysHatFilter extends JeelizFilter {
  LuffysHatFilter({
    this.part = LuffysHatPart.part2,
    this.textureMaxWidth = 512,
    this.showFrame = true,
    this.mirrorVideo = true,
  });

  final LuffysHatPart part;

  /// Both hat textures are ~2048px JPEGs.
  final int textureMaxWidth;

  /// Part 2's `cadre_v1.png`. Part 1 has no frame and ignores this.
  final bool showFrame;

  /// Must match the overlay's mirroring. Only part 2 samples the camera.
  final bool mirrorVideo;

  // --- part 1 -------------------------------------------------------------

  /// `hatMesh.scale.multiplyScalar(1.2)`.
  static const double kPart1Scale = 1.2;

  /// `hatMesh.rotation.set(0, -40, 0)`, in radians. See the header.
  static const double kPart1RotationY = -40.0;

  /// `hatMesh.position.set(0.0, 0.6, 0.0)`.
  static const Vec3 kPart1Position = Vec3(0, 0.6, 0);

  // --- part 2 -------------------------------------------------------------

  /// `HATMESH.scale.multiplyScalar(1.1 * 1.1)`.
  static const double kPart2HatScale = 1.1 * 1.1;

  /// `HATMESH.rotation.set(-0.1, 0, 0)`.
  static const double kPart2HatRotationX = -0.1;

  /// `HATMESH.position.set(0.0, 0.7, -0.3)`.
  static const Vec3 kPart2HatPosition = Vec3(0, 0.7, -0.3);

  /// `FACEMESH.scale.multiplyScalar(1.12 * 1.1)`.
  static const double kPart2FaceScale = 1.12 * 1.1;

  /// `FACEMESH.position.set(0, 0.5, -0.75)`.
  static const Vec3 kPart2FacePosition = Vec3(0, 0.5, -0.75);

  /// `SETTINGS.pivotOffsetYZ = [0.2, 0.6 - 0.1]`, pushed into the helper by
  /// `JeelizThreeHelper.set_pivotOffsetYZ()` before init.
  ///
  /// This is a *tracking* setting, not a scene one — it moves the point the
  /// head appears to rotate about, so the hat swings correctly rather than
  /// sliding. Whoever builds the controller has to honour
  /// [preferredPivotOffsetYZ] for part 2 to sit right.
  static const List<double> kPart2PivotOffsetYZ = <double>[0.2, 0.5];

  /// `addDragEventListener(HATOBJ3D)` — part 2 only, and it drags the group,
  /// so hat and face fill move together.
  Vec3 offset = Vec3.zero;

  bool get isDraggable => part == LuffysHatPart.part2;

  BufferGeometry? _hatGeometry;
  BufferGeometry? _faceGeometry;
  Texture2D? _hatTexture;
  HelmetFaceMaterial? _faceMat;
  ui.Image? _frame;
  Object3D? _root;

  /// The face fill's material, for tests. Null on part 1.
  HelmetFaceMaterial? get faceMaterial => _faceMat;

  @override
  List<double>? get preferredPivotOffsetYZ =>
      part == LuffysHatPart.part2 ? kPart2PivotOffsetYZ : null;

  /// Only part 2 has the face fill, and only that samples the camera.
  @override
  bool get needsVideo => part == LuffysHatPart.part2;

  @override
  bool get needsVideoColor => part == LuffysHatPart.part2;

  @override
  ui.Image? get foreground => _frame;

  @override
  Future<void> load() async {
    _hatGeometry = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/luffys_hat.json'));

    // Part 1 uses models/Texture.jpg; part 2 uses the different, browner
    // models/luffys_hat/Texture2.jpg. (The demo also ships a third,
    // models/Texture2.jpg, that neither loads.)
    final textureName =
        part == LuffysHatPart.part1 ? 'Texture.jpg' : 'Texture2.jpg';
    _hatTexture = await Texture2D.decode(
      await loadJeelizAssetUint8List('$_kAssetDir/$textureName'),
      maxWidth: textureMaxWidth,
    );

    if (part == LuffysHatPart.part2) {
      // Byte-identical to rupy_helmet's copy, so it is loaded from that
      // filter's asset directory rather than shipped twice.
      _faceGeometry = decodeBufferGeometry(
          await loadJeelizAssetString('rupyHelmet/faceLowPolyEyesEarsFill2.json'));

      if (showFrame) {
        final bytes = await loadJeelizAssetUint8List('$_kAssetDir/cadre_v1.png');
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
        _frame = (await codec.getNextFrame()).image;
        codec.dispose();
      }
    }
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final hatGeometry = _hatGeometry;
    final hatTexture = _hatTexture;
    if (hatGeometry == null || hatTexture == null) return;

    // `MeshBasicMaterial({map: ...})` — unlit, which is why the demos' ambient
    // light does nothing.
    final hatMat = BasicColorMaterial(map: hatTexture);

    if (part == LuffysHatPart.part1) {
      // Part 1 parents the mesh straight to the face object; there is no group
      // and nothing to drag.
      final hat = Mesh(hatGeometry, hatMat, name: 'luffysHat')
        ..scale = const Vec3(kPart1Scale, kPart1Scale, kPart1Scale)
        ..rotation = const Euler(0, kPart1RotationY, 0)
        ..position = kPart1Position;
      helper.faceObject.add(hat);
      _root = hat;
      return;
    }

    final group = Object3D(name: 'luffysHatGroup');

    final hat = Mesh(hatGeometry, hatMat, name: 'luffysHat')
      ..scale = const Vec3(kPart2HatScale, kPart2HatScale, kPart2HatScale)
      ..rotation = const Euler(kPart2HatRotationX, 0, 0)
      ..position = kPart2HatPosition;
    group.add(hat);

    final faceGeometry = _faceGeometry;
    if (faceGeometry != null) {
      // The same shader as rupy_helmet's, with two constants widened: the
      // silhouette fade runs to 0.85 instead of 0.55 and the darkening to 0.15
      // instead of 0.05.
      final mat = _faceMat = HelmetFaceMaterial(
        mirrorVideo: mirrorVideo,
        borderHigh: HelmetFaceMaterial.kLuffyBorderHigh,
        darkenHigh: HelmetFaceMaterial.kLuffyDarkenHigh,
      );
      final face = Mesh(faceGeometry, mat, name: 'luffysFaceFill')
        ..scale =
            const Vec3(kPart2FaceScale, kPart2FaceScale, kPart2FaceScale)
        ..position = kPart2FacePosition;
      group.add(face);
    }

    helper.faceObject.add(group);
    _root = group;
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final r = _root;
    if (r != null) helper.faceObject.remove(r);
    _root = null;
    _faceMat = null;
  }

  @override
  void setVideo(VideoLumaTexture? video) => _faceMat?.video = video;

  @override
  void update(DetectState state, double dt) {
    final r = _root;
    if (r != null && isDraggable) r.position = offset;
  }
}
