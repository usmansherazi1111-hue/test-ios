// Port of demos/threejs/dog_face.
//
// Three pieces on one draggable group:
//
//   * ears — FlexMaterial, so they swing behind the head (amortization 0.1);
//   * nose — plain Phong with a bump map;
//   * tongue — FlexMaterial (amortization 0.3) over a 26-frame morph animation,
//     which unrolls when the mouth opens and rolls back up when it closes.
//
// Plus a pink vignette laid over the whole frame.
//
// Three things the original does indirectly, resolved here:
//
// 1. The tongue's animation is never authored as a clip. Its morph targets are
//    named `animation_000000…025`, and three's JSONLoader spots that pattern and
//    calls `AnimationClip.CreateClipsFromMorphTargetSequences(targets, 10)`,
//    which builds one triangle-wave influence track per frame at 10fps. Play
//    that back and at any instant exactly two neighbouring frames have non-zero
//    influence, summing to 1 — i.e. it is a plain lerp along a 26-frame
//    sequence. [_TongueAnimation] is that, directly.
//
// 2. `MIXER.update(0.16)` advances 160ms per *frame*, not 16ms. Whether that is
//    a typo or intent, it makes the tongue whip out in about half a second, and
//    it is reproduced.
//
// 3. The pink overlay is built at runtime with glfx.js: `texture_pink.jpg` →
//    `vignette(0.5, 0.6)` → drawn at 20% alpha. glfx's vignette is one line of
//    GLSL, so it is evaluated here on the CPU at load instead of shipping a
//    pre-baked image.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/flex_material.dart';
import '../core/geometry.dart';
import '../core/legacy_geometry.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'dogFace';

class DogFaceFilter extends JeelizFilter {
  DogFaceFilter({
    this.textureWidth = 512,
    this.showVignette = true,
  });

  /// Decode width for the diffuse and bump maps.
  final int textureWidth;

  /// Whether to build the pink vignette overlay.
  final bool showVignette;

  Object3D? _group;
  Mesh? _ears;
  Mesh? _nose;
  Mesh? _tongue;
  FlexMaterial? _earsMat;
  FlexMaterial? _tongueMat;
  _TongueAnimation? _anim;
  ui.Image? _vignette;

  /// `addDragEventListener(DOGOBJ3D)` — drag to fit.
  Vec3 offset = Vec3.zero;

  @override
  ui.Image? get foreground => _vignette;

  /// Exposed for tests and tuning: how far through the unroll the tongue is.
  double get tongueProgress => _anim?.progress ?? 0;
  bool get isTongueOut => _anim?.isOut ?? false;

  @override
  Future<void> load() async {
    Future<Texture2D> tex(String name, {int? max}) async => Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/$name'),
        maxWidth: max ?? textureWidth);

    // --- ears ---------------------------------------------------------
    final earsGeom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/dog_ears.json'));

    _earsMat = FlexMaterial(
      flexMap: await tex('flex_ears_256.jpg', max: 256),
      map: await tex('texture_ears.jpg'),
      alphaMap: await tex('alpha_ears_256.jpg', max: 256),
      bumpMap: await tex('normal_ears.jpg'),
      bumpScale: 0.0075,
      shininess: 1.5,
      specular: const Vec3(1, 1, 1),
      transparent: true,
    );

    _ears = Mesh(earsGeom, _earsMat!, name: 'dogEars')
      ..scale = const Vec3(0.025, 0.025, 0.025)
      ..position = const Vec3(0, -0.3, 0)
      ..renderOrder = 10000;

    // --- nose ---------------------------------------------------------
    final noseGeom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/dog_nose.json'));

    _nose = Mesh(
      noseGeom,
      PhongMaterial(
        map: await tex('texture_nose.jpg'),
        bumpMap: await tex('normal_nose.jpg'),
        bumpScale: 0.005,
        shininess: 1.5,
        specular: const Vec3(1, 1, 1),
      ),
      name: 'dogNose',
    )
      ..scale = const Vec3(0.018, 0.018, 0.018)
      ..position = const Vec3(0, -0.05, 0.15)
      ..renderOrder = 10000;

    // --- tongue -------------------------------------------------------
    // Legacy `Geometry` format, because it carries the morph targets.
    final tongue = decodeLegacyGeometry(
        await loadJeelizAssetString('$_kAssetDir/dog_tongue.json'));

    _tongueMat = FlexMaterial(
      flexMap: await tex('flex_tongue_256.png', max: 256),
      map: await tex('dog_tongue.jpg'),
      alphaMap: await tex('tongue_alpha_256.jpg', max: 256),
      transparent: true,
      opacity: 0,
    );

    final tongueGeom = BufferGeometry(
      positions: tongue.geometry.positions,
      indices: tongue.geometry.indices,
      normals: tongue.geometry.normals,
      uvs: tongue.geometry.uvs,
      morphPositions: tongue.morphFrames,
    );

    _tongue = Mesh(tongueGeom, _tongueMat!, name: 'dogTongue')
      ..scale = const Vec3(2, 2, 2)
      ..position = const Vec3(0, -0.28, 0)
      ..visible = false;
    _tongue!.morphInfluences = List<double>.filled(tongue.morphFrames.length, 0);

    _anim = _TongueAnimation(tongue.morphFrames.length);

    if (showVignette) _vignette = await _buildVignette();
  }

  /// `apply_filter()`: texture_pink.jpg through glfx's vignette, at 20% alpha.
  ///
  /// ```glsl
  /// float dist = distance(texCoord, vec2(0.5, 0.5));
  /// color.rgb *= smoothstep(0.8, size * 0.799, dist * (amount + size));
  /// ```
  ///
  /// with `size = 0.5`, `amount = 0.6`. Note the edges are reversed (0.8 down to
  /// ~0.4), which is what makes it darken outwards rather than inwards.
  Future<ui.Image> _buildVignette() async {
    final pink = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/texture_pink.jpg'),
        maxWidth: 256);

    const size = 0.5, amount = 0.6;
    final w = pink.width, h = pink.height;
    final out = Uint8List(w * h * 4);
    final texel = Float64List(4);

    for (var y = 0; y < h; y++) {
      final v = (y + 0.5) / h;
      for (var x = 0; x < w; x++) {
        final u = (x + 0.5) / w;
        pink.sampleTopDown(u, v, texel);

        final du = u - 0.5, dv = v - 0.5;
        final dist = math.sqrt(du * du + dv * dv);
        final k = smoothstep(0.8, size * 0.799, dist * (amount + size));

        final i = (y * w + x) * 4;
        // Premultiplied by the 0.2 alpha, which is how the canvas composite in
        // the original ends up too.
        const a = 0.2;
        out[i] = (texel[0] * k * a * 255).round().clamp(0, 255);
        out[i + 1] = (texel[1] * k * a * 255).round().clamp(0, 255);
        out[i + 2] = (texel[2] * k * a * 255).round().clamp(0, 255);
        out[i + 3] = (a * 255).round();
      }
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(out);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    return frame.image;
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    _group = Object3D(name: 'dog')
      ..add(_ears!)
      ..add(_nose!)
      ..add(_tongue!);
    helper.faceObject.add(_group!);

    helper.scene.add(AmbientLight(color: const Vec3(1, 1, 1), intensity: 0.8));
    helper.scene.add(
      DirectionalLight(color: const Vec3(1, 1, 1), intensity: 0.5)
        ..position = const Vec3(100, 1000, 1000),
    );
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    if (_group != null) helper.faceObject.remove(_group!);
  }

  @override
  void update(DetectState state, double dt) {
    _group?.position = offset;
    if (state.detected <= 0) return;

    // The flex materials need each mesh's *world* transform. matrixWorld is
    // refreshed by the renderer at the start of every frame, so this reads the
    // previous frame's — exactly the one-frame lag the original has, since it
    // does the same thing from callbackTrack.
    final ears = _ears, tongue = _tongue;
    if (ears != null) {
      final d = decomposeWorldMatrix(ears.matrixWorld);
      _earsMat?.setAmortized(
        position: d.position,
        scale: d.scale,
        euler: d.euler,
        amortization: 0.1,
      );
    }
    if (tongue != null) {
      final d = decomposeWorldMatrix(tongue.matrixWorld);
      _tongueMat?.setAmortized(
        position: d.position,
        scale: d.scale,
        euler: d.euler,
        amortization: 0.3,
      );
    }

    // Mouth-open gate. The original latches on >= 0.85 and off on <= 0.1, so
    // the tongue does not flutter while the mouth hovers mid-way.
    final anim = _anim;
    if (anim != null) {
      anim.setTarget(state.mouthOpening);
      anim.advance(dt);
      _tongueMat?.opacity = anim.opacity;
      _tongue?.visible = anim.opacity > 0.002;
      anim.writeInfluences(_tongue?.morphInfluences);
    }
  }
}

/// The tongue's unroll, as the 26-frame lerp three's generated clip reduces to.
///
/// Also carries the opacity tween the original runs alongside it (150ms out,
/// 100ms back) and the latching mouth-open gate.
class _TongueAnimation {
  _TongueAnimation(this.frameCount);

  final int frameCount;

  /// `MIXER.update(0.16)` per frame at ~30fps, against a clip built at 10fps —
  /// so the playhead advances 1.6 frames per rendered frame.
  static const double kFramesPerSecond = 10.0;
  static const double kMixerStepPerFrame = 0.16;

  /// 0 = rolled up, 1 = fully out.
  double progress = 0;
  double opacity = 0;
  bool isOut = false;

  bool _wantOut = false;

  void setTarget(double mouthOpening) {
    if (mouthOpening >= 0.85) _wantOut = true;
    if (mouthOpening <= 0.1) _wantOut = false;
  }

  void advance(double dt) {
    // The clip is frameCount/fps seconds long; the mixer is stepped a fixed
    // 0.16s per frame rather than by dt, which is what the original does.
    final clipSeconds = frameCount / kFramesPerSecond;
    final step = kMixerStepPerFrame / clipSeconds;

    if (_wantOut) {
      progress = math.min(1.0, progress + step);
      opacity = math.min(1.0, opacity + dt / 0.1); // 100ms fade in
      if (progress >= 1.0) isOut = true;
    } else {
      progress = math.max(0.0, progress - step);
      opacity = math.max(0.0, opacity - dt / 0.15); // 150ms fade out
      if (progress <= 0.0) isOut = false;
    }
  }

  /// Writes the two-frame lerp into [influences].
  void writeInfluences(List<double>? influences) {
    if (influences == null || influences.isEmpty) return;
    for (var i = 0; i < influences.length; i++) {
      influences[i] = 0;
    }

    final last = frameCount - 1;
    if (last <= 0) {
      influences[0] = 1;
      return;
    }

    final pos = clampd(progress, 0, 1) * last;
    final i0 = pos.floor().clamp(0, last);
    final i1 = (i0 + 1).clamp(0, last);
    final t = pos - i0;

    influences[i0] = 1.0 - t;
    if (i1 != i0) influences[i1] = t;
  }
}
