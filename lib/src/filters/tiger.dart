// Port of demos/threejs/tiger — the `init_threeScene()` and `callbackTrack()`
// halves of main.js.
//
// Every constant is the demo's. The two places this necessarily departs from
// the original are called out inline: TWEEN.js becomes a few lines of linear
// interpolation, and `detectState.expressions[0]` comes from landmark geometry
// rather than from Jeeliz's expression network.

import 'dart:math' as math;
import 'dart:typed_data';

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
import 'tiger_material.dart';

const String _kAssetDir = 'tiger';

/// The tiger head filter.
///
/// Four materials on one mesh (whiskers, eyes, face skin, inside ears), a
/// black quad behind the mouth, and 200 additive sprites that fire when the
/// user opens their mouth.
class TigerFilter extends JeelizFilter {
  TigerFilter({
    this.particleCount = 200,
    this.textureWidth = 512,
    this.mirrorVideo = true,
  });

  /// The demo uses a fixed pool "to avoid memory dynamic allocation", and so
  /// do we — 200 sprites are allocated once and recycled.
  final int particleCount;

  /// Decode width for headTexture2.png. The original is 1024x1024, which is
  /// far more than a face-sized object resolves on a phone.
  final int textureWidth;

  /// Must match the overlay's mirroring, or the video wash around the eyes
  /// slides the wrong way.
  final bool mirrorVideo;

  late TigerMaskMaterial _skinMat;
  late TigerMaskMaterial _eyesMat;
  Mesh? _maskMesh;
  Mesh? _mouthHideMesh;

  final List<_Particle> _particles = [];
  int _shotIndex = 0;
  final math.Random _rng = math.Random();

  @override
  bool get needsVideo => true;

  @override
  Future<void> load() async {
    final geom = decodeBufferGeometry(
        await loadJeelizAssetString('$_kAssetDir/TigerHead.json'));

    final headTexture = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/headTexture2.png'),
        maxWidth: textureWidth);

    // white.png is literally one white pixel; no need to decode it.
    final whiteTexture = Texture2D.solid(255, 255, 255);

    _skinMat = TigerMaskMaterial(map: headTexture)..mirrorVideo = mirrorVideo;
    _eyesMat = TigerMaskMaterial(map: whiteTexture)..mirrorVideo = mirrorVideo;

    final whiskersMat = LambertMaterial(color: const Vec3(1, 1, 1));
    final insideEarsMat = BasicColorMaterial(
        color: const Vec3(0x33 / 255, 0x11 / 255, 0x00 / 255));

    // Order matters: it indexes the geometry's groups.
    //   0 whiskers, 1 eyes, 2 face skin, 3 inside ears.
    _maskMesh = Mesh.multiMaterial(
      geom,
      [whiskersMat, _eyesMat, _skinMat, insideEarsMat],
      name: 'tigerHead',
    )
      ..scale = const Vec3(2, 3, 2)
      ..position = const Vec3(0, 0.2, -0.48);

    _mouthHideMesh = Mesh(
      planeGeometry(0.5, 0.6),
      BasicColorMaterial(color: Vec3.zero),
      name: 'tigerMouthHide',
    )..position = const Vec3(0, -0.35, 0.5);

    _buildParticles();
  }

  void _buildParticles() {
    final spriteTexture = _generateSpriteTexture();
    final spriteMat = SpriteMaterial(map: spriteTexture);

    for (var i = 0; i < particleCount; i++) {
      final sprite = Sprite(spriteMat, name: 'particle$i')
        ..visible = false
        ..scale = Vec3.zero;
      _particles.add(_Particle(sprite));
    }
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final face = helper.faceObject;
    face.add(_maskMesh!);
    face.add(_mouthHideMesh!);

    final particlesRoot = Object3D(name: 'particles');
    for (final p in _particles) {
      particlesRoot.add(p.sprite);
    }
    face.add(particlesRoot);
    _particlesRoot = particlesRoot;

    // AND THERE WAS LIGHT.
    helper.scene.add(AmbientLight(color: const Vec3(1, 1, 1), intensity: 0.3));
    helper.scene.add(
      DirectionalLight(
        color: const Vec3(0xff / 255, 0x88 / 255, 0x33 / 255),
        intensity: 2,
      )..position = const Vec3(0, 0.5, 1),
    );
  }

  Object3D? _particlesRoot;

  @override
  void setVideo(VideoLumaTexture? video) {
    _skinMat.video = video;
    _eyesMat.video = video;
  }

  @override
  void update(DetectState state, double dt) {
    if (state.detected > 0) {
      // The demo remaps its network's raw output with `(expressions[0] - 0.2)
      // * 5`. That constant describes Jeeliz's network, not mouth opening;
      // our adapter already reports a calibrated 0..1, so no curve is applied
      // here. See LandmarkDetectStateAdapter._mouthOpening.
      final mouthOpening = clampd(state.mouthOpening, 0, 1);

      _skinMat.mouthOpening = mouthOpening;
      _eyesMat.mouthOpening = mouthOpening;

      final hide = _mouthHideMesh;
      if (hide != null) {
        hide.scale = Vec3(1, 1.0 + mouthOpening * 0.4, 1);
      }

      if (mouthOpening > 0.5) {
        _fireParticle(state);
      }
    }

    _updateParticles(dt);
  }

  void _fireParticle(DetectState state) {
    final p = _particles[_shotIndex];
    _shotIndex = (_shotIndex + 1) % _particles.length;
    if (p.visible) return; // already in flight

    final theta = _rng.nextDouble() * 6.28;

    // The demo rotates the direction by the face object's own rotation even
    // though the particles are already parented to it, so the rotation lands
    // twice. Reproduced rather than corrected — it is what gives the spray its
    // sideways lean when the head turns.
    final dir = Vec3(0.5 * math.cos(theta), 0.5 * math.sin(theta), 1)
        .applyEuler(Euler(state.rx, state.ry, state.rz, EulerOrder.zyx));

    p.start(
      from: Vec3(
        0.5 * (_rng.nextDouble() - 0.5),
        -0.35 + 0.5 * (_rng.nextDouble() - 0.5),
        0.5,
      ),
      to: dir * 10.0,
      scaleFrom: _rng.nextDouble() * 0.6,
      scaleTo: 0.8,
      duration: (2000 + 40 * _rng.nextDouble()) / 1000.0,
    );
  }

  void _updateParticles(double dt) {
    for (final p in _particles) {
      p.advance(dt);
    }
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final face = helper.faceObject;
    if (_maskMesh != null) face.remove(_maskMesh!);
    if (_mouthHideMesh != null) face.remove(_mouthHideMesh!);
    if (_particlesRoot != null) face.remove(_particlesRoot!);
  }

  /// `generate_sprite()` — a 16x16 radial gradient, drawn on the CPU instead
  /// of on a canvas2D. Uniform 50% alpha, RGB running white -> cyan -> navy ->
  /// black, which with additive blending reads as a spark.
  Texture2D _generateSpriteTexture() {
    const size = 16;
    final px = Uint8List(size * size * 4);
    const stops = <(double, int, int, int)>[
      (0.0, 255, 255, 255),
      (0.2, 0, 255, 255),
      (0.4, 0, 0, 64),
      (1.0, 0, 0, 0),
    ];

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x + 0.5 - size / 2, dy = y + 0.5 - size / 2;
        // The canvas gradient has radius width/2 and fillRect covers the whole
        // square, so anything past the last stop clamps to it.
        final t = clampd(math.sqrt(dx * dx + dy * dy) / (size / 2), 0, 1);

        var r = 0.0, g = 0.0, b = 0.0;
        for (var i = 0; i < stops.length - 1; i++) {
          final (t0, r0, g0, b0) = stops[i];
          final (t1, r1, g1, b1) = stops[i + 1];
          if (t >= t0 && t <= t1) {
            final k = (t1 - t0) < 1e-9 ? 0.0 : (t - t0) / (t1 - t0);
            r = r0 + (r1 - r0) * k;
            g = g0 + (g1 - g0) * k;
            b = b0 + (b1 - b0) * k;
            break;
          }
        }

        final i = (y * size + x) * 4;
        px[i] = r.round();
        px[i + 1] = g.round();
        px[i + 2] = b.round();
        px[i + 3] = 128; // every stop is rgba(..., 0.5)
      }
    }
    return Texture2D(size, size, px);
  }
}

/// One pooled sprite plus its two linear tweens.
///
/// TWEEN.js defaults to `Linear.None`, so replacing it costs exactly this.
class _Particle {
  _Particle(this.sprite);

  final Sprite sprite;

  bool visible = false;
  double _t = 0, _duration = 0;
  Vec3 _from = Vec3.zero, _to = Vec3.zero;
  double _scaleFrom = 0, _scaleTo = 0;

  void start({
    required Vec3 from,
    required Vec3 to,
    required double scaleFrom,
    required double scaleTo,
    required double duration,
  }) {
    _from = from;
    _to = to;
    _scaleFrom = scaleFrom;
    _scaleTo = scaleTo;
    _duration = duration <= 0 ? 1e-3 : duration;
    _t = 0;
    visible = true;
    sprite
      ..visible = true
      ..position = from
      ..scale = Vec3(scaleFrom, scaleFrom, 1);
  }

  void advance(double dt) {
    if (!visible) return;
    _t += dt;
    final k = _t / _duration;
    if (k >= 1.0) {
      visible = false;
      sprite
        ..visible = false
        ..scale = Vec3.zero;
      return;
    }
    sprite.position = _from.lerp(_to, k);
    final s = _scaleFrom + (_scaleTo - _scaleFrom) * k;
    sprite.scale = Vec3(s, s, 1);
  }
}

/// three's `PlaneBufferGeometry(width, height)`: a quad in the XY plane facing
/// +Z, wound counter-clockwise so it survives front-face culling.
BufferGeometry planeGeometry(double width, double height) {
  final hw = width / 2, hh = height / 2;
  return BufferGeometry(
    positions: Float32List.fromList([
      -hw, -hh, 0, //
      hw, -hh, 0, //
      hw, hh, 0, //
      -hw, hh, 0,
    ]),
    indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
    normals: Float32List.fromList([
      0, 0, 1, //
      0, 0, 1, //
      0, 0, 1, //
      0, 0, 1,
    ]),
    uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
  );
}
