// Port of demos/threejs/halloween_spider — open your mouth and spiders crawl out.
//
// Three meshes on one group: two spiders with 121-frame morph animations, and a
// low-poly face that redraws the camera video so the spiders can pass behind
// your head. The animation is triggered by mouth opening rather than running on
// a loop, which makes this the first ported filter that *waits* for you.
//
// Four things in the original do nothing, and two of them are whole assets:
//
//  * `models/face/diffuse_makeup.png` is loaded into a `MeshBasicMaterial` that
//    is then thrown away — `faceMesh` is built with `materialVideo` instead. The
//    makeup never reaches the screen, so this port does not ship the file.
//  * The face shader computes `darkenCoeff` and `borderCoeff` and outputs
//    neither: `gl_FragColor = vec4(videoColor, 1)`. It is rupy_helmet's face
//    shader with the payload deleted, leaving an opaque video redraw.
//  * An `AmbientLight` and a `SpotLight` are added to the scene. Both spiders
//    are `MeshBasicMaterial`, which is unlit, and the face is a custom shader.
//    Neither light can affect anything.
//  * Both spider JSONs carry 80 bones. The meshes are plain `Mesh`es, not
//    `SkinnedMesh`es, and the material never sets `skinning: true`, so the
//    skeleton is inert — the movement is entirely morph targets.
//
// And one that is wrong but works. `action.loop = false` sets three's `loop`
// property to `0`, which is not `LoopOnce` (2200) — so `_updateTime` takes the
// *repeat* branch and the clip loops. The demo then listens for the mixer's
// `'loop'` event and stops the action there. Net effect: it plays exactly once,
// by way of starting to loop and being caught. Ported as "play once", which is
// what it does.

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/legacy_geometry.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../core/video_texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'halloweenSpider';

class HalloweenSpiderFilter extends JeelizFilter {
  HalloweenSpiderFilter({
    this.showFrame = true,
    this.textureMaxWidth = 512,
    this.mirrorVideo = true,
    this.morphStride = 1,
  }) : assert(morphStride >= 1);

  /// `cadre_halloween.png`.
  final bool showFrame;

  /// `diffuse_spider.jpg` is 1024x1024 and shared by both spiders.
  final int textureMaxWidth;

  /// Must match the overlay's mirroring — the face mesh samples the camera.
  final bool mirrorVideo;

  /// Keeps every Nth morph frame instead of all 121.
  ///
  /// The two spiders carry 121 frames each over 11,568 de-indexed corners,
  /// which is about 17 MB of `Float32List` apiece. Raising this trades
  /// smoothness for memory and is the only knob that moves that number; it
  /// changes the animation, so it defaults to 1.
  final int morphStride;

  /// `MASKOBJ3D.scale.multiplyScalar(0.59)`.
  static const double kGroupScale = 0.59;

  /// `MASKOBJ3D.position.z -= 0.5` and `.y += 0.4`.
  static const Vec3 kGroupPosition = Vec3(0, 0.4, -0.5);

  /// `smallSpiderMesh.position.y -= 0.2`. The big spider's equivalent line is
  /// commented out in the original.
  static const double kSmallSpiderY = -0.2;

  /// `detectState.expressions[0] >= 0.8` — mouth opening, on the same 0..1
  /// scale the tiger's fire-breathing uses.
  static const double kMouthTrigger = 0.8;

  /// `mixer.update(0.08)` — a fixed step per rendered frame, not real time, and
  /// only while a face is detected. Same shape as butterflies' 0.13.
  static const double kMixerStepSeconds = 0.08;

  /// `AnimationClip.CreateClipsFromMorphTargetSequences(morphTargets, 10)`.
  static const double kMorphFps = 10.0;

  LegacyGeometry? _smallGeometry;
  LegacyGeometry? _bigGeometry;
  BufferGeometry? _faceGeometry;
  Texture2D? _spiderTexture;
  ui.Image? _frame;

  Object3D? _root;
  Mesh? _small;
  Mesh? _big;
  Mesh? _face;
  SpiderFaceMaterial? _faceMat;

  int _frameCount = 0;

  /// Seconds into the clip, advanced only while playing.
  double _clock = 0;
  bool _playing = false;

  /// `isAnimating` — stops a held-open mouth from retriggering every frame.
  bool get isAnimating => _playing;

  /// The two spiders, for tests. Empty before [attach].
  List<Mesh> get spiders =>
      <Mesh>[if (_small != null) _small!, if (_big != null) _big!];

  /// The video-redraw face mesh, for tests.
  Mesh? get faceMesh => _face;

  @override
  bool get needsVideo => true;

  /// The face shader outputs `texture2D(samplerVideo, vUVvideo).rgb`, so it
  /// needs real colour rather than the luma the tiger gets away with.
  @override
  bool get needsVideoColor => true;

  @override
  ui.Image? get foreground => _frame;

  @override
  Future<void> load() async {
    _smallGeometry = decodeLegacyGeometry(
        await loadJeelizAssetString('$_kAssetDir/small_spider.json'));
    _bigGeometry = decodeLegacyGeometry(
        await loadJeelizAssetString('$_kAssetDir/big_spider.json'));
    _faceGeometry = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/face.json'));

    // Byte-identical between the two model directories, so it is shipped and
    // decoded once.
    _spiderTexture = await Texture2D.decode(
      await loadJeelizAssetUint8List('$_kAssetDir/diffuse_spider.jpg'),
      maxWidth: textureMaxWidth,
    );

    if (showFrame) {
      final bytes =
          await loadJeelizAssetUint8List('$_kAssetDir/cadre_halloween.png');
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
      _frame = (await codec.getNextFrame()).image;
      codec.dispose();
    }
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final small = _smallGeometry;
    final big = _bigGeometry;
    final faceGeom = _faceGeometry;
    final texture = _spiderTexture;
    if (small == null || big == null || faceGeom == null || texture == null) {
      return;
    }

    final root = Object3D(name: 'halloweenSpider')
      ..scale = const Vec3(kGroupScale, kGroupScale, kGroupScale)
      ..position = kGroupPosition;

    // `loadingManager.onLoad` adds the face first, then the two spiders. Order
    // matters only for the transparent pass, and the face is opaque, so this
    // is really just fidelity.
    _faceMat = SpiderFaceMaterial(mirrorVideo: mirrorVideo);
    _face = Mesh(faceGeom, _faceMat!, name: 'spiderFace');
    root.add(_face!);

    _small = _buildSpider(small, texture, 'smallSpider')
      ..position = const Vec3(0, kSmallSpiderY, 0);
    root.add(_small!);

    // The big spider's `position.y += 0.1` is commented out in the demo.
    _big = _buildSpider(big, texture, 'bigSpider');
    root.add(_big!);

    _frameCount = _small!.morphInfluences.length;

    helper.faceObject.add(root);
    _root = root;
  }

  Mesh _buildSpider(LegacyGeometry source, Texture2D texture, String name) {
    final frames = morphStride == 1
        ? source.morphFrames
        : <Float32List>[
            for (var i = 0; i < source.morphFrames.length; i += morphStride)
              source.morphFrames[i],
          ];

    final geometry = BufferGeometry(
      positions: source.geometry.positions,
      indices: source.geometry.indices,
      normals: source.geometry.normals,
      uvs: source.geometry.uvs,
      groups: source.geometry.groups,
      morphPositions: frames,
    );

    // `new THREE.MeshBasicMaterial({map, morphTargets: true})` — unlit, which
    // is why the scene's two lights change nothing.
    return Mesh(geometry, BasicColorMaterial(map: texture), name: name)
      ..morphInfluences = List<double>.filled(frames.length, 0);
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final r = _root;
    if (r != null) helper.faceObject.remove(r);
    _root = null;
    _small = null;
    _big = null;
    _face = null;
    _faceMat = null;
    _playing = false;
    _clock = 0;
  }

  @override
  void setVideo(VideoLumaTexture? video) => _faceMat?.video = video;

  @override
  void update(DetectState state, double dt) {
    // `if (ISDETECTED)` wraps both the trigger and the mixer update, so the
    // spiders freeze the moment tracking is lost and resume where they were.
    if (state.detected <= 0) return;

    final mouth = state.expressions.isEmpty ? 0.0 : state.expressions[0];
    if (mouth >= kMouthTrigger && !_playing) {
      _playing = true;
      _clock = 0;
    }

    if (!_playing) return;

    _clock += kMixerStepSeconds;

    final n = _frameCount;
    if (n == 0) return;

    // 121 frames at the loader's 10 fps, so 12.1 s of clip. The demo lets the
    // clip start to loop and stops it on the mixer's 'loop' event, so it plays
    // through exactly once and resets.
    final duration = n / kMorphFps;
    if (_clock >= duration) {
      _playing = false;
      _clock = 0;
      _writeInfluences(-1, -1, 0);
      return;
    }

    final frame = _clock * kMorphFps;
    final i0 = frame.floor() % n;
    final i1 = (i0 + 1) % n;
    _writeInfluences(i0, i1, frame - frame.floor());
  }

  int _lastA = -1, _lastB = -1;

  /// Two adjacent frames are the only ones ever non-zero — see butterflies for
  /// why a morph-target clip reduces to that — so clearing just those two beats
  /// wiping 121 entries twice a frame.
  void _writeInfluences(int a, int b, double t) {
    for (final mesh in spiders) {
      final w = mesh.morphInfluences;
      if (w.isEmpty) continue;
      if (_lastA >= 0 && _lastA < w.length) w[_lastA] = 0;
      if (_lastB >= 0 && _lastB < w.length) w[_lastB] = 0;
      if (a >= 0 && a < w.length) w[a] = 1.0 - t;
      if (b >= 0 && b < w.length) w[b] = t;
    }
    _lastA = a;
    _lastB = b;
  }
}

/// The face mesh's shader.
///
/// ```glsl
/// vec3 videoColor = texture2D(samplerVideo, vUVvideo).rgb;
/// float darkenCoeff = smoothstep(-0.15, 0.05, vY);
/// float borderCoeff = smoothstep(0.0, 0.55, vNormalDotZ);
/// gl_FragColor = vec4(videoColor, 1 );
/// ```
///
/// Both coefficients are dead. This is rupy_helmet's face shader with its two
/// commented-out debug outputs left in and the real one deleted, so what
/// remains is an **opaque redraw of the camera at the face's position**. It
/// looks like nothing when the head is bare, and that is the point: it gives
/// the spiders something to disappear behind.
///
/// The vertex stage still computes `vY` and `vNormalDotZ`, and the material is
/// still flagged `transparent: true` despite writing alpha 1. Neither reaches
/// the screen, so neither is reproduced.
class SpiderFaceMaterial extends Material {
  SpiderFaceMaterial({this.video, this.mirrorVideo = false});

  VideoLumaTexture? video;
  bool mirrorVideo;

  /// The original sets `transparent: true`, then writes `1` for alpha. Kept as
  /// transparent so the draw order matches; nothing is ever blended.
  @override
  bool get transparent => true;

  /// No normal is read — the shader's only use for one is the dead
  /// `vNormalDotZ`.
  @override
  bool get needsNormals => false;

  @override
  bool shade(Fragment f, Float64List out) {
    var u = f.vpU;
    if (mirrorVideo) u = 1.0 - u;

    final vid = video;
    if (vid == null) {
      out[0] = out[1] = out[2] = 0;
    } else {
      vid.sampleRgb(u, f.vpV, out);
    }
    out[3] = 1;
    return true;
  }
}
