// Port of demos/threejs/rupy_helmet.
//
// Three meshes on one draggable group:
//
//   * the helmet — Phong, diffuse-mapped, shininess 50;
//   * the visor — MeshStandardMaterial, white, 50% opaque, front side only;
//   * a low-poly face fill that redraws the *camera video* darkened, so the
//     wearer's face reads as being in shadow inside the helmet.
//
// That third mesh is the interesting one, and it is the reason this filter
// needed colour video rather than the luma the tiger got away with.
//
// Two constants in the original are inert and reproduced as such:
// `reflectionRatio: 1` on the helmet is not a three.js property at all (the
// real one is `reflectivity`, and even that needs an envMap), and the visor's
// `transparent: true` is passed twice in the same object literal.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'rupyHelmet';

/// The low-poly face fill.
///
/// Port of the `ShaderMaterial` in main.js. The vertex stage forwards two
/// scalars and the fragment stage is three lines:
///
/// ```glsl
/// vY = position.y * cos(THETAHEAD) - position.z * sin(THETAHEAD); // 0.25 rad
/// vNormalDotZ = pow(abs(normalView.z), 1.5);
/// ...
/// vec3 videoColor = texture2D(samplerVideo, vUVvideo).rgb;
/// float darkenCoeff = smoothstep(-0.15, 0.05, vY);
/// float borderCoeff = smoothstep(0.0, 0.55, vNormalDotZ);
/// gl_FragColor = vec4(videoColor * (1. - darkenCoeff), borderCoeff);
/// ```
///
/// So: sample the video where this pixel lands, fade it to black going *up*
/// the head (in a frame tilted back by 0.25 rad, which is roughly the head's
/// own tilt), and fade the whole thing out at the silhouette where the normal
/// turns away from the camera. Drawn first (`renderOrder = -10000`), it darkens
/// the face before the helmet lands on top.
class HelmetFaceMaterial extends Material {
  HelmetFaceMaterial({
    this.video,
    this.mirrorVideo = false,
    this.borderHigh = kRupyBorderHigh,
    this.darkenHigh = kRupyDarkenHigh,
  });

  /// Camera frame. Null until the first one arrives.
  VideoLumaTexture? video;

  /// Must match the overlay's mirroring, or the darkened fill samples the
  /// wrong side of the face.
  bool mirrorVideo;

  /// `const float THETAHEAD = 0.25;`
  static const double kThetaHead = 0.25;

  /// luffys_hat_part2 ships this same shader with two constants changed, so
  /// they are parameters rather than a second copy of the material. The
  /// defaults are rupy_helmet's.
  ///
  /// `smoothstep(0.0, borderHigh, vNormalDotZ)` — how far into the profile the
  /// fill stays opaque. Luffy's 0.85 keeps a much wider soft edge than rupy's
  /// 0.55, which suits a mask that has to disappear under a straw brim rather
  /// than inside a helmet shell.
  static const double kRupyBorderHigh = 0.55;
  static const double kLuffyBorderHigh = 0.85;
  final double borderHigh;

  /// `smoothstep(-0.15, darkenHigh, vY)` — where the darkening stops on the way
  /// up the face. Luffy's 0.15 spreads it over twice the height of rupy's 0.05.
  static const double kRupyDarkenHigh = 0.05;
  static const double kLuffyDarkenHigh = 0.15;
  final double darkenHigh;

  @override
  bool get transparent => true;

  final Float64List _rgb = Float64List(3);

  @override
  bool shade(Fragment f, Float64List out) {
    // vNormalDotZ = pow(abs(normalView.z), 1.5) — 1 facing the camera, 0 at
    // the silhouette, so this is the alpha that hides the mesh's own edge.
    var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
    if (nl < 1e-12) nl = 1;
    final absNz = (f.nz / nl).abs();
    final normalDotZ = absNz * math.sqrt(absNz); // pow(x, 1.5)

    final borderCoeff = smoothstep(0.0, borderHigh, normalDotZ);
    if (borderCoeff <= 0.002) return false;

    // vY, in a frame rotated back by THETAHEAD.
    final vY = f.oy * math.cos(kThetaHead) - f.oz * math.sin(kThetaHead);
    final darkenCoeff = smoothstep(-0.15, darkenHigh, vY);

    // The original computes the video UV per vertex from the projected
    // position and interpolates it. Using the fragment's own screen position
    // is both simpler and closer to the intent — sample the video *at this
    // pixel* — since perspective-correct interpolation of per-vertex screen
    // positions does not reproduce the fragment's screen position anyway.
    var u = f.vpU;
    if (mirrorVideo) u = 1.0 - u;

    final vid = video;
    if (vid == null) {
      _rgb[0] = _rgb[1] = _rgb[2] = 0;
    } else {
      vid.sampleRgb(u, f.vpV, _rgb);
    }

    final k = 1.0 - darkenCoeff;
    out[0] = _rgb[0] * k;
    out[1] = _rgb[1] * k;
    out[2] = _rgb[2] * k;
    out[3] = borderCoeff;
    return true;
  }
}

class RupyHelmetFilter extends JeelizFilter {
  RupyHelmetFilter({
    this.textureWidth = 512,
    this.showFrame = true,
    this.mirrorVideo = true,
  });

  /// Decode width for `diffuse_helmet.jpg` (1MB of JPEG).
  final int textureWidth;

  /// Whether to load `frame_rupy.png`, the demo's full-screen frame.
  final bool showFrame;

  /// Must match the overlay's mirroring — see [HelmetFaceMaterial.mirrorVideo].
  final bool mirrorVideo;

  Object3D? _group;
  late HelmetFaceMaterial _faceMat;
  ui.Image? _frame;

  /// The demo drags the whole `HELMETOBJ3D`, not one mesh, so the offset lands
  /// on the group and carries helmet, visor and face fill together.
  Vec3 offset = Vec3.zero;

  @override
  bool get needsVideo => true;

  /// The face fill uses `videoColor.rgb` as colour, so luma is not enough.
  @override
  bool get needsVideoColor => true;

  @override
  ui.Image? get foreground => _frame;

  @override
  Future<void> load() async {
    final helmetGeom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/helmet.json'));
    final visorGeom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/visiere.json'));
    // Positions only — no normals, no UVs — so they get computed on load,
    // exactly as `maskBufferGeometry.computeVertexNormals()` does in the JS.
    final faceGeom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/faceLowPolyEyesEarsFill2.json'));

    final helmetTexture = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/diffuse_helmet.jpg'),
        maxWidth: textureWidth);

    final helmet = Mesh(
      helmetGeom,
      PhongMaterial(map: helmetTexture, shininess: 50),
      name: 'helmet',
    );
    final visor = Mesh(
      visorGeom,
      StandardMaterial(
        color: const Vec3(1, 1, 1),
        opacity: 0.5,
        transparent: true,
      ),
      name: 'visor',
    );

    // Helmet and visor share a transform in the original, applied separately
    // to each: scale 0.037, down 0.3, back 0.5, pitched 0.5 rad.
    for (final m in [helmet, visor]) {
      m
        ..scale = const Vec3(0.037, 0.037, 0.037)
        ..position = const Vec3(0, -0.3, -0.5)
        ..rotation = const Euler(0.5, 0, 0);
    }

    _faceMat = HelmetFaceMaterial(mirrorVideo: mirrorVideo);
    final face = Mesh(faceGeom, _faceMat, name: 'faceFill')
      ..renderOrder = -10000
      ..scale = const Vec3(1.12, 1.12, 1.12)
      ..position = const Vec3(0, 0.3, -0.25);

    _group = Object3D(name: 'helmetGroup')
      ..add(helmet)
      ..add(visor)
      ..add(face);

    if (showFrame) {
      final bytes = await loadJeelizAssetUint8List('$_kAssetDir/frame_rupy.png');
      final codec = await ui.instantiateImageCodec(bytes);
      _frame = (await codec.getNextFrame()).image;
      codec.dispose();
    }
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    helper.faceObject.add(_group!);

    // `new THREE.AmbientLight(0x404040)` — no intensity argument, so 1.0.
    helper.scene.add(AmbientLight(
      color: const Vec3(0x40 / 255, 0x40 / 255, 0x40 / 255),
    ));
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
  void setVideo(VideoLumaTexture? video) => _faceMat.video = video;

  @override
  void update(DetectState state, double dt) {
    _group?.position = offset;
  }
}
