// Port of demos/threejs/fireworks — rockets launching off your head.
//
// Structurally the simplest filter here: 1,020 additive sprites and a pile of
// tweens, no geometry, no lights, no camera sampling. What makes it worth
// reading closely is that almost every number in it is off by something, and
// the result is what the demo looks like:
//
//  * `for (let i = 0; i <= SETTINGS.numberRockets; i++)` with
//    `numberRockets = 9` builds **ten** rockets. (butterflies has the same bug
//    in the other direction — its loop starts at 2 and produces fewer than the
//    constant says.) The same `<=` gives **101** particles per burst, not 100.
//  * `theta = Math.log10(Math.random() * 2 * Math.PI)` — the *log* of an angle.
//    Certainly meant to be the angle itself. It squashes the burst into a fan
//    instead of a circle, and that is the shape on screen.
//  * The sprite's radial gradient has **two stops at offset 0.5** and one out
//    of order at 0.2, so it is cyan in the middle, ramps to white, jumps
//    discontinuously to the burst colour, and fades out. Sorting the stops
//    "properly" would give a completely different sprite.
//  * `particle.rotation._z = particle.rotation.z * Math.random()` writes
//    three's *private* Euler field, so no change callback fires and the
//    quaternion never updates. It is also multiplying by zero. And a Sprite
//    takes its roll from `material.rotation`, not the object. Inert three ways.
//  * `particle.scale.multiplyScalar(3)` at construction is overwritten by
//    `scale.x = scale.y = Math.random() * 0.1` before the particle is ever
//    drawn.
//  * Particles are shown and never hidden. After a burst finishes they sit at
//    their end position at scale 0.0001 — sub-pixel, but still submitted every
//    frame.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/assets.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'fireworks';

class FireworksFilter extends JeelizFilter {
  FireworksFilter({
    this.showFrame = true,
    this.particlesPerRocket = kParticlesPerRocket,
    int? randomSeed,
  }) : _rng = math.Random(randomSeed ?? 0x46495245);

  /// `frame_fireworks.png`, the demo's full-screen border.
  final bool showFrame;

  /// Lowered only to trade sparks for frame time; the demo's number is
  /// [kParticlesPerRocket].
  final int particlesPerRocket;

  /// `SETTINGS.numberRockets = 9`, but `i <= numberRockets` builds ten.
  static const int kNumberRockets = 9;
  static int get rocketCount => kNumberRockets + 1;

  /// `for (let i = 0; i <= 100; i++)` — 101, not 100.
  static const int kParticlesPerRocket = 101;

  /// `SETTINGS.radiusEnd = 100`, used as `0.04 * radiusEnd` — so 4 face units.
  static const double kRadiusEnd = 100;
  static const double kRadiusScale = 0.04;

  /// `SETTINGS.animationDuration = 2000`, in seconds here.
  static const double kBurstSeconds = 2.0;

  /// `new TWEEN.Tween(rocket.position).to({y: 1}, 2000)`.
  static const double kFlightSeconds = 2.0;

  /// `setTimeout(..., 3000)` between a burst and the next launch.
  static const double kReloadSeconds = 3.0;

  /// `setTimeout(..., 1200*index)` staggering the first launches.
  static const double kLaunchStaggerSeconds = 1.2;

  /// `rocket.position.y = -4` at launch, tweened to `y: 1`.
  static const double kRocketStartY = -4.0;
  static const double kRocketEndY = 1.0;

  /// `rocket.scale.multiplyScalar(0.08)`.
  static const double kRocketScale = 0.08;

  /// The ten burst colours, one per rocket. Two rockets are red, three are
  /// yellow, and only one is pink.
  static const List<String> kColors = <String>[
    'red',
    'yellow',
    'green',
    'blue',
    'pink',
    'red',
    'yellow',
    'green',
    'blue',
    'yellow',
  ];

  final math.Random _rng;

  Object3D? _root;
  ui.Image? _frame;
  final List<_Rocket> _rockets = <_Rocket>[];

  Texture2D? _rocketSprite;
  final Map<String, Texture2D> _burstSprites = <String, Texture2D>{};

  double _elapsed = 0;

  /// The rocket sprites, for tests.
  List<Sprite> get rockets =>
      List<Sprite>.unmodifiable(_rockets.map((r) => r.sprite));

  /// Every burst particle, flattened, for tests.
  List<Sprite> get particles =>
      <Sprite>[for (final r in _rockets) ...r.particles];

  @override
  ui.Image? get foreground => _frame;

  @override
  Future<void> load() async {
    // `new THREE.CanvasTexture(generate_sprite())` — a 32x32 canvas painted
    // with a radial gradient. No image file is involved in the original
    // either; the sprite is code.
    _rocketSprite = fireworksSprite();
    for (final c in kColors.toSet()) {
      _burstSprites[c] = fireworksSprite(color: c);
    }

    if (showFrame) {
      final bytes =
          await loadJeelizAssetUint8List('$_kAssetDir/frame_fireworks.png');
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1024);
      _frame = (await codec.getNextFrame()).image;
      codec.dispose();
    }
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final rocketSprite = _rocketSprite;
    if (rocketSprite == null) return;

    final root = Object3D(name: 'fireworks');

    // One SpriteMaterial per texture, shared by everything that uses it —
    // the demo shares the rocket material across all ten rockets and one
    // material per colour across that colour's particles.
    final rocketMat =
        SpriteMaterial(map: rocketSprite, blend: BlendMode.additive);
    final burstMats = <String, SpriteMaterial>{
      for (final e in _burstSprites.entries)
        e.key: SpriteMaterial(map: e.value, blend: BlendMode.additive),
    };

    for (var i = 0; i < rocketCount; i++) {
      final sprite = Sprite(rocketMat, name: 'rocket$i')
        ..scale = const Vec3(kRocketScale, kRocketScale, kRocketScale)
        ..position = const Vec3(0, kRocketStartY, 0)
        ..renderOrder = 100000
        ..visible = false;
      root.add(sprite);

      final colour = kColors[i % kColors.length];
      final mat = burstMats[colour]!;
      final parts = <Sprite>[];
      for (var p = 0; p < particlesPerRocket; p++) {
        final particle = Sprite(mat, name: 'spark${i}_$p')
          // `scale.multiplyScalar(3)`, overwritten before it is ever drawn.
          ..scale = const Vec3(3, 3, 3)
          ..renderOrder = 100000
          ..visible = false;
        parts.add(particle);
        root.add(particle);
      }

      _rockets.add(_Rocket(
        index: i,
        sprite: sprite,
        particles: parts,
        launchAt: kLaunchStaggerSeconds * i,
        rng: _rng,
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
    _rockets.clear();
    _elapsed = 0;
  }

  @override
  void update(DetectState state, double dt) {
    _elapsed += dt;
    for (final r in _rockets) {
      r.update(_elapsed);
    }
  }
}

/// One rocket and the burst it turns into.
class _Rocket {
  _Rocket({
    required this.index,
    required this.sprite,
    required this.particles,
    required this.launchAt,
    required math.Random rng,
  })  : _rng = rng,
        _sparks = List<_Spark>.generate(
            particles.length, (_) => _Spark(), growable: false);

  final int index;
  final Sprite sprite;
  final List<Sprite> particles;
  final double launchAt;
  final math.Random _rng;
  final List<_Spark> _sparks;

  /// When the current flight began. Negative until the first launch.
  double _flightStart = double.negativeInfinity;

  /// When the burst began, or negative infinity before the first one.
  double _burstStart = double.negativeInfinity;

  double _x = 0;
  bool _launched = false;

  void update(double now) {
    if (!_launched) {
      if (now < launchAt) return;
      _launch(launchAt);
    }

    // `1200*index` for the first, then 2 s of flight and 3 s of reload.
    final sinceLaunch = now - _flightStart;
    if (sinceLaunch < FireworksFilter.kFlightSeconds) {
      // The rocket's own tween: position.y from -4 to 1, linear, which is
      // TWEEN.js's default easing.
      final t = sinceLaunch / FireworksFilter.kFlightSeconds;
      sprite
        ..visible = true
        ..position = Vec3(
          _x,
          FireworksFilter.kRocketStartY +
              (FireworksFilter.kRocketEndY - FireworksFilter.kRocketStartY) * t,
          0,
        );
    } else {
      sprite.visible = false;
      if (_burstStart < _flightStart) {
        _burst(_flightStart + FireworksFilter.kFlightSeconds);
      }
      final reloadAt = _flightStart +
          FireworksFilter.kFlightSeconds +
          FireworksFilter.kReloadSeconds;
      if (now >= reloadAt) _launch(reloadAt);
    }

    _advanceSparks(now);
  }

  void _launch(double at) {
    _launched = true;
    _flightStart = at;
    // `((Math.random()*0.5) + 0.5) * (random > 0 ? 1 : -1)` — magnitude in
    // [0.5, 1.0], sign either way, so a rocket never launches from dead centre.
    final positive = _rng.nextDouble() * 2 - 1 > 0 ? 1.0 : -1.0;
    _x = (_rng.nextDouble() * 0.5 + 0.5) * positive;
    sprite.position = Vec3(_x, FireworksFilter.kRocketStartY, 0);
  }

  /// `animate_particle`, once per particle, all at the rocket's position.
  void _burst(double at) {
    _burstStart = at;
    final from = Vec3(_x, FireworksFilter.kRocketEndY, 0);
    const r = FireworksFilter.kRadiusScale * FireworksFilter.kRadiusEnd;

    for (var i = 0; i < particles.length; i++) {
      // `Math.log10(Math.random() * 2 * Math.PI)`. Guarded against a zero
      // draw, which would give -infinity and then NaN positions — a
      // probability-zero case in the original too, but a NaN here would
      // poison the rasteriser rather than just look odd.
      final u = _rng.nextDouble();
      final arg = u * 2 * math.pi;
      final theta = arg <= 1e-12 ? math.log(1e-12) / math.ln10
                                 : math.log(arg) / math.ln10;
      final phi = (_rng.nextDouble() * 2 - 1) * math.pi / 4;

      _sparks[i]
        ..from = from
        // Only x and y are tweened; z stays where the rocket left it.
        ..to = Vec3(
          r * math.cos(theta) * math.sin(phi),
          r * math.sin(theta) * math.cos(phi),
          0,
        )
        ..fromScale = _rng.nextDouble() * 0.1
        ..active = true;
      particles[i].visible = true;
    }
  }

  void _advanceSparks(double now) {
    if (_burstStart.isInfinite) return;
    // Clamped at 1: the tween finishes and the particle simply stays there,
    // because nothing ever hides it again.
    var t = (now - _burstStart) / FireworksFilter.kBurstSeconds;
    if (t < 0) t = 0;
    if (t > 1) t = 1;

    for (var i = 0; i < particles.length; i++) {
      final s = _sparks[i];
      if (!s.active) continue;
      particles[i].position = Vec3(
        s.from.x + (s.to.x - s.from.x) * t,
        s.from.y + (s.to.y - s.from.y) * t,
        s.from.z + (s.to.z - s.from.z) * t,
      );
      // `to({x: 0.0001, y: 0.0001}, 2000)`. scale.z is left at the 3 the
      // constructor set, and a Sprite ignores it.
      final k = s.fromScale + (0.0001 - s.fromScale) * t;
      particles[i].scale = Vec3(k, k, 3);
    }
  }
}

class _Spark {
  Vec3 from = Vec3.zero;
  Vec3 to = Vec3.zero;
  double fromScale = 0;
  bool active = false;
}

/// Port of `generate_sprite(color)` — the 32x32 canvas the demo paints its
/// particles with.
///
/// ```js
/// const gradient = context.createRadialGradient(16, 16, 0, 16, 16, 16);
/// gradient.addColorStop(0.5, 'rgba(255,255,255,1)');
/// gradient.addColorStop(0.2, 'rgba(0,255,255,1)');
/// gradient.addColorStop(0.5, color ? color : 'blue');
/// gradient.addColorStop(1, 'rgba(0,0,0,0.1)');
/// ```
///
/// Two things about that list are load-bearing. The stops are **out of order**
/// — 0.5, then 0.2, then 0.5 — and canvas sorts them by offset while keeping
/// insertion order for ties. And there are **two stops at 0.5**, which the
/// spec resolves as a discontinuity: the earlier-added colour applies up to the
/// offset and the later-added one from it. So the sprite reads:
///
///   * 0.0 - 0.2  flat cyan
///   * 0.2 - 0.5  cyan ramping to white
///   * 0.5        a hard jump from white to the burst colour
///   * 0.5 - 1.0  the burst colour fading to `rgba(0,0,0,0.1)`
///
/// Canvas interpolates gradients in **premultiplied** space, which is why that
/// last segment stays saturated as it fades instead of going muddy.
///
/// The gradient's radius is half the canvas, so the corners are past its end
/// and take the final stop flat.
Texture2D fireworksSprite({String? color, int size = 32}) {
  final end = _cssColor(color ?? 'blue');
  const cyan = <double>[0, 1, 1, 1];
  const white = <double>[1, 1, 1, 1];
  const outer = <double>[0, 0, 0, 0.1];

  final px = Uint8List(size * size * 4);
  final centre = size / 2.0;
  final radius = size / 2.0;
  final rgba = Float64List(4);

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x + 0.5 - centre, dy = y + 0.5 - centre;
      var t = math.sqrt(dx * dx + dy * dy) / radius;
      if (t > 1) t = 1;

      if (t <= 0.2) {
        rgba.setAll(0, cyan);
      } else if (t < 0.5) {
        _mixPremultiplied(cyan, white, (t - 0.2) / 0.3, rgba);
      } else {
        // At exactly 0.5 the later-added stop wins, so the jump to the burst
        // colour happens *at* the boundary rather than after it.
        _mixPremultiplied(end, outer, (t - 0.5) / 0.5, rgba);
      }

      final i = (y * size + x) * 4;
      px[i] = (rgba[0] * 255).round().clamp(0, 255);
      px[i + 1] = (rgba[1] * 255).round().clamp(0, 255);
      px[i + 2] = (rgba[2] * 255).round().clamp(0, 255);
      px[i + 3] = (rgba[3] * 255).round().clamp(0, 255);
    }
  }
  return Texture2D(size, size, px);
}

/// Canvas gradient interpolation: lerp in premultiplied space, then divide the
/// alpha back out.
void _mixPremultiplied(
    List<double> a, List<double> b, double t, Float64List out) {
  final aa = a[3], ba = b[3];
  final alpha = aa + (ba - aa) * t;
  for (var k = 0; k < 3; k++) {
    final p = a[k] * aa + (b[k] * ba - a[k] * aa) * t;
    out[k] = alpha <= 1e-9 ? 0.0 : p / alpha;
  }
  out[3] = alpha;
}

/// The five CSS colour names the demo uses, plus its default.
///
/// `green` is worth flagging: CSS `green` is **#008000**, a dark green, not
/// #00FF00. Two of the ten bursts are that muted.
List<double> _cssColor(String name) {
  const table = <String, List<int>>{
    'red': <int>[255, 0, 0],
    'yellow': <int>[255, 255, 0],
    'green': <int>[0, 128, 0],
    'blue': <int>[0, 0, 255],
    'pink': <int>[255, 192, 203],
  };
  final c = table[name];
  if (c == null) throw ArgumentError('unknown colour name "$name"');
  return <double>[c[0] / 255, c[1] / 255, c[2] / 255, 1.0];
}
