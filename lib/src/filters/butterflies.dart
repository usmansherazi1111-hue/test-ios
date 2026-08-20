// Port of demos/threejs/butterflies — a swarm of butterflies orbiting the head.
//
// Nine butterflies, each sharing one 692-triangle mesh and one set of 106 morph
// frames, each with its own wing texture, its own cyan point light, and its own
// phase through the same orbit. They arrive one at a time, 600 ms apart.
//
// This demo is the loosest-written of the ones ported so far, and four of its
// details are dead or surprising. All four are reproduced, because the
// alternative is a filter that does not look like the original:
//
// 1. `for (let i = 2; i <= NUMBERBUTTERFLIES; i++)` starts at **2**, so
//    `NUMBERBUTTERFLIES = 10` produces **nine** butterflies, not ten. The index
//    is also the animation's phase parameter, so starting at 2 changes what the
//    swarm looks like, not just how big it is.
// 2. The mesh is built with two materials, `[materialWings, materialBody]` —
//    but no face in `butterfly.json` carries a material index (bit 1 of the
//    face bitfield is never set), so every triangle uses material 0 and
//    `materialBody` is never drawn. Its `opacity: 0` without `transparent: true`
//    would have made it an opaque black blob if it ever had been.
// 3. `animateFly(mesh, theta, index)` never reads `theta`, and `sign` is
//    computed for every butterfly and never used.
// 4. There is **no ambient or directional light in the scene at all**. The only
//    illumination is the nine point lights, each of which tweens down to zero
//    intensity. A butterfly whose light is at the bottom of its cycle is a black
//    silhouette, not an invisible one — its alpha map still cuts the wing shape
//    out. The "glow" is the whole lighting model.

import 'dart:math' as math;
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/geometry.dart';
import '../core/legacy_geometry.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'butterflies';

class ButterfliesFilter extends JeelizFilter {
  ButterfliesFilter({
    this.showGrass = true,
    this.textureMaxWidth = 256,
    int? randomSeed,
  }) : _rng = math.Random(randomSeed ?? 20180719);

  /// Whether to load `grass.png`, the strip the demo lays across the bottom of
  /// the page in CSS rather than in the scene.
  final bool showGrass;

  /// The wing textures are 1024x1024 JPEGs and there are six of them. Decoding
  /// at full size costs 25 MB of RGBA for detail no butterfly at this scale can
  /// show.
  final int textureMaxWidth;

  /// `NUMBERBUTTERFLIES = 10`, but the loop runs `i = 2; i <= 10`.
  static const int kNumberButterflies = 10;
  static const int kFirstIndex = 2;

  /// How many butterflies actually exist. Nine.
  static int get count => kNumberButterflies - kFirstIndex + 1;

  /// `butterFlyInstance.scale.multiplyScalar(0.55)`.
  static const double kScale = 0.55;

  /// `setTimeout(..., 600*i)` — the delay before butterfly `i` appears.
  static const double kSpawnIntervalSeconds = 0.6;

  /// `setInterval(..., 16)` drives `animateFly`, one `count += 0.01` per tick.
  ///
  /// A `setInterval` is a wall-clock timer, so this is driven from real elapsed
  /// time rather than per rendered frame — which is both the intent and, on a
  /// browser that is keeping up, the behaviour.
  static const double kFlyCountPerSecond = 0.01 / 0.016;

  /// `m.update(0.13)` — a **fixed** step, once per `callbackTrack`, not the
  /// real elapsed time.
  ///
  /// Unlike the flight path this one is genuinely per-frame: the author picked
  /// 0.13 by eye against their own frame rate. Reproduced as written, so the
  /// wings beat at the same rate relative to the orbit as they do in the demo.
  /// Set [wingStepSeconds] to null to drive the wings from real time instead.
  static const double kWingStepSeconds = 0.13;

  /// `AnimationClip.CreateClipsFromMorphTargetSequences(morphTargets, 10)` —
  /// the JSONLoader's hard-coded 10 fps.
  static const double kMorphFps = 10.0;

  /// `setTimeout(() => a.play(), index*33)` — the wing cycles are shifted so the
  /// swarm does not beat in unison.
  static const double kWingPhaseStagger = 0.033;

  /// `new THREE.PointLight(0x77ffff, 1, 1, 0.1)`.
  static const Vec3 kLightColor = Vec3(0x77 / 255, 1.0, 1.0);
  static const double kLightDistance = 1.0;
  static const double kLightDecay = 0.1;

  /// The tween chain: `intensity -> 0.6` over 2 s, then `-> 0` over 2 s, then
  /// the up-tween restarts. So the first ramp runs 1 -> 0.6 and every one after
  /// it runs 0 <-> 0.6. TWEEN.js defaults to linear easing.
  static const double kLightIntensityHigh = 0.6;
  static const double kLightTweenSeconds = 2.0;

  /// Set null to drive the wing animation from real elapsed time.
  double? wingStepSeconds = kWingStepSeconds;

  final math.Random _rng;

  LegacyGeometry? _geometry;
  Texture2D? _alphaMap;
  final List<Texture2D> _diffuse = <Texture2D>[];
  ui.Image? _grass;

  Object3D? _root;
  final List<_Butterfly> _butterflies = <_Butterfly>[];

  double _elapsed = 0;

  /// The live butterflies, for tests.
  List<Mesh> get meshes =>
      List<Mesh>.unmodifiable(_butterflies.map((b) => b.mesh));

  /// Their point lights, for tests.
  List<PointLight> get lights =>
      List<PointLight>.unmodifiable(_butterflies.map((b) => b.light));

  @override
  ui.Image? get foreground => _grass;

  @override
  ForegroundLayout get foregroundLayout => ForegroundLayout.bottomVmin;

  @override
  Future<void> load() async {
    final json = await loadJeelizAssetString('$_kAssetDir/butterfly.json');
    _geometry = decodeLegacyGeometry(json);

    // Through the asset-root probe, not `Texture2D.load`, which takes a
    // literal bundle key and so would miss the `packages/jeeliz_dart/` prefix
    // when this package is a dependency rather than the app.
    _alphaMap = await _texture('Wing_Alpha.jpg');
    for (var t = 1; t <= 5; t++) {
      _diffuse.add(await _texture('Wing_Diffuse_$t.jpg'));
    }

    if (showGrass) {
      final bytes = await loadJeelizAssetUint8List('$_kAssetDir/grass.png');
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
      _grass = (await codec.getNextFrame()).image;
      codec.dispose();
    }
  }

  Future<Texture2D> _texture(String name) async => Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/$name'),
        maxWidth: textureMaxWidth,
      );

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final geometry = _geometry;
    if (geometry == null) return;

    // `morphPositions` is a geometry property, so the frames are folded into
    // one BufferGeometry here and shared by all nine meshes — the demo shares
    // its geometry object the same way.
    final shared = BufferGeometry(
      positions: geometry.geometry.positions,
      indices: geometry.geometry.indices,
      normals: geometry.geometry.normals,
      uvs: geometry.geometry.uvs,
      groups: geometry.geometry.groups,
      morphPositions: geometry.morphFrames,
    );

    final root = Object3D(name: 'butterflies');

    for (var i = kFirstIndex; i <= kNumberButterflies; i++) {
      // `indexTexture = i % 6 === 0 ? 1 : i % 6` — 1..5, with 1 used twice and
      // 5 only once. i=6 and i=7 both land on texture 1.
      final textureIndex = i % 6 == 0 ? 1 : i % 6;

      final material = LambertMaterial(
        map: _diffuse[textureIndex - 1],
        alphaMap: _alphaMap,
        transparent: true,
        // `opacity: 0` at construction; the setTimeout raises it to 1. Since
        // this material *is* transparent, unlike the body's, the zero counts —
        // which is what keeps a butterfly hidden until its turn.
        opacity: 0.0,
      );

      final mesh = Mesh(shared, material, name: 'butterfly$i')
        ..morphInfluences = List<double>.filled(geometry.morphFrames.length, 0)
        ..scale = const Vec3(kScale, kScale, kScale)
        ..visible = false;

      final light = PointLight(
        color: kLightColor,
        intensity: 1.0,
        distance: kLightDistance,
        decay: kLightDecay,
      );

      // `xRand = random()*2 - 1`, `yRand = random()*1 + 0.1`,
      // `zRand = random()*1 + 0.5`. These never survive as positions — the
      // first tick of animateFly overwrites all three — but they set the radii
      // of the orbit, so they are the whole shape of the flight path.
      final origin = Vec3(
        _rng.nextDouble() * 2 - 1,
        _rng.nextDouble() * 1 + 0.1,
        _rng.nextDouble() * 1 + 0.5,
      );

      // An empty parent per butterfly, exactly as the demo builds it. It
      // carries no transform of its own; the mesh and the light are both
      // positioned in face space directly.
      final holder = Object3D(name: 'butterflyHolder$i')
        ..add(mesh)
        ..add(light);
      root.add(holder);

      _butterflies.add(_Butterfly(
        index: i,
        mesh: mesh,
        material: material,
        light: light,
        holder: holder,
        origin: origin,
        spawnAt: kSpawnIntervalSeconds * i,
        wingPhase: kWingPhaseStagger * (i - kFirstIndex),
        morphFrameCount: geometry.morphFrames.length,
      ));
    }

    helper.faceObject.add(root);
    _root = root;
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final r = _root;
    if (r != null) helper.faceObject.remove(r);
    _root = null;
    _butterflies.clear();
    _elapsed = 0;
  }

  @override
  void update(DetectState state, double dt) {
    _elapsed += dt;
    final wingStep = wingStepSeconds ?? dt;
    for (final b in _butterflies) {
      b.update(_elapsed, dt, wingStep);
    }
  }
}

/// One butterfly: mesh, light, and the three animations running on them.
class _Butterfly {
  _Butterfly({
    required this.index,
    required this.mesh,
    required this.material,
    required this.light,
    required this.holder,
    required this.origin,
    required this.spawnAt,
    required this.wingPhase,
    required this.morphFrameCount,
  });

  final int index;
  final Mesh mesh;
  final LambertMaterial material;
  final PointLight light;
  final Object3D holder;
  final Vec3 origin;

  /// `600*i` milliseconds.
  final double spawnAt;

  /// `index*33` milliseconds on the clip's start.
  final double wingPhase;

  final int morphFrameCount;

  /// `count` in `animateFly`. Only starts once the butterfly has appeared —
  /// `animateFly` is called from inside the same setTimeout.
  double flyCount = 0;

  /// Seconds into the wing clip.
  double wingTime = 0;

  bool spawned = false;

  void update(double elapsed, double dt, double wingStep) {
    if (!spawned) {
      if (elapsed < spawnAt) return;
      spawned = true;
      // Everything the setTimeout does at once: show the mesh, raise both
      // opacities, and start the animations.
      mesh.visible = true;
      material.opacity = 1.0;
    }

    flyCount += dt * ButterfliesFilter.kFlyCountPerSecond;
    wingTime += wingStep;

    _fly();
    _flapWings();
    _tweenLight(elapsed - spawnAt);
  }

  /// ```js
  /// mesh.position.set(
  ///   (x + index*0.01) * Math.cos(count),
  ///   (y*0.5 + index*0.01) * Math.sin(count*0.2*index) + 1,
  ///   (z + index*0.01) * Math.sin(count)
  /// );
  /// mesh.rotation.y = 1.5*Math.cos(count+0.05) + 0.3;
  /// mesh.rotation.z = 0.2*Math.sin(count);
  /// ```
  ///
  /// An ellipse in XZ whose two radii are the butterfly's random x and z, with
  /// a much slower vertical bob around y = 1. Because the vertical rate is
  /// `0.2*index`, the nine butterflies drift in and out of plane at nine
  /// different speeds and the swarm never repeats.
  ///
  /// The demo runs this on the mesh *and* on the point light, from the same
  /// starting position and with the same index, so the light tracks its
  /// butterfly exactly. Here one evaluation drives both.
  void _fly() {
    final c = flyCount;
    final k = index * 0.01;

    final p = Vec3(
      (origin.x + k) * math.cos(c),
      (origin.y * 0.5 + k) * math.sin(c * 0.2 * index) + 1,
      (origin.z + k) * math.sin(c),
    );

    mesh.position = p;
    light.position = p;

    // rotation.x is left at 0; the default XYZ Euler order applies.
    mesh.rotation = Euler(0, 1.5 * math.cos(c + 0.05) + 0.3, 0.2 * math.sin(c));
  }

  /// The morph clip the JSONLoader builds from 106 sequentially-named targets.
  ///
  /// Each target gets a triangular ramp — 0 at frame `g-1`, 1 at `g`, 0 at
  /// `g+1` — so at any moment exactly two adjacent targets are active and their
  /// influences sum to 1. That is linear interpolation between consecutive
  /// frames, and evaluating it directly is both cheaper and exactly equivalent
  /// to running an AnimationMixer over 106 keyframe tracks.
  ///
  /// The clip is 106 frames at 10 fps, so one full cycle is 10.6 seconds of
  /// clip time. At the fixed 0.13 s step that is ~82 rendered frames.
  void _flapWings() {
    final influences = mesh.morphInfluences;
    if (influences.isEmpty) return;

    final n = morphFrameCount;
    var frame = (wingTime + wingPhase) * ButterfliesFilter.kMorphFps;
    frame %= n;
    if (frame < 0) frame += n;

    final i0 = frame.floor() % n;
    final i1 = (i0 + 1) % n;
    final f = frame - frame.floor();

    // Only two entries are ever non-zero, so clear the two from last frame
    // rather than the whole 106-long list.
    if (_lastA >= 0) influences[_lastA] = 0;
    if (_lastB >= 0) influences[_lastB] = 0;
    influences[i0] = 1.0 - f;
    influences[i1] = f;
    _lastA = i0;
    _lastB = i1;
  }

  int _lastA = -1;
  int _lastB = -1;

  /// ```js
  /// opacityUp   = tween(light).to({intensity: 0.6}, 2000);
  /// opacityDown = tween(light).to({intensity: 0}, 2000);
  /// opacityUp.chain(opacityDown);
  /// opacityDown.onComplete(() => opacityUp.start());
  /// opacityUp.start();
  /// ```
  ///
  /// The light is constructed at intensity 1, so the **first** up-tween runs
  /// 1 -> 0.6 and every one after it runs 0 -> 0.6. Linear, which is TWEEN.js's
  /// default easing.
  void _tweenLight(double since) {
    const span = ButterfliesFilter.kLightTweenSeconds;
    const high = ButterfliesFilter.kLightIntensityHigh;

    if (since <= 0) {
      light.intensity = 1.0;
      return;
    }
    if (since < span) {
      // The one-off opening ramp, down from the constructor's 1.
      light.intensity = 1.0 + (high - 1.0) * (since / span);
      return;
    }

    // Then a 4 s triangle: 0.6 -> 0 over the first half, 0 -> 0.6 over the
    // second.
    final cycle = (since - span) % (2 * span);
    light.intensity = cycle < span
        ? high * (1.0 - cycle / span)
        : high * ((cycle - span) / span);
  }
}
