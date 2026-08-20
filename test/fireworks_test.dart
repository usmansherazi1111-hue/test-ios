// Tests for demos/threejs/fireworks.
//
// This demo is a pile of off-by-ones and misused maths, and the tests exist
// mostly to hold each one in place: ten rockets from `numberRockets = 9`, 101
// particles from `i <= 100`, a sprite gradient whose stops are out of order and
// doubled, and an explosion angle that is the *logarithm* of an angle. Every
// one of them is exactly the sort of thing a port would tidy up into looking
// wrong.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(FireworksFilter, JeelizFaceFilterHelper, PerspectiveCamera)> build({
    bool frame = false,
    int? particles,
    int seed = 1,
  }) async {
    final f = FireworksFilter(
      showFrame: frame,
      particlesPerRocket: particles ?? FireworksFilter.kParticlesPerRocket,
      randomSeed: seed,
    );
    await f.load();
    final helper = JeelizFaceFilterHelper();
    final camera = helper.createCamera();
    helper.updateCamera(camera,
        canvasWidth: 240, canvasHeight: 320, videoWidth: 240, videoHeight: 320);
    f.attach(helper);
    return (f, helper, camera);
  }

  const head =
      DetectState(detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);

  void advance(FireworksFilter f, double seconds, {double dt = 1 / 30}) {
    var t = 0.0;
    while (t < seconds) {
      f.update(head, dt);
      t += dt;
    }
  }

  group('the sprite', () {
    /// Samples the generated 32x32 sprite along a horizontal ray from the
    /// centre, at radius fraction [t].
    List<double> at(Texture2D tex, double t) {
      final centre = tex.width / 2.0;
      final x = (centre + t * centre).clamp(0.0, tex.width - 1.0).floor();
      final y = (centre - 0.5).floor();
      final i = (y * tex.width + x) * 4;
      return [
        tex.rgba[i] / 255,
        tex.rgba[i + 1] / 255,
        tex.rgba[i + 2] / 255,
        tex.rgba[i + 3] / 255,
      ];
    }

    test('is 32x32, like the canvas', () {
      final s = fireworksSprite();
      expect(s.width, 32);
      expect(s.height, 32);
    });

    test('is cyan in the middle, not white', () {
      // The stop at 0.2 is added *second* but sorts first, so everything
      // inside 20% of the radius is flat cyan — the "0.5 white" stop the code
      // reads as first never reaches the centre.
      final s = fireworksSprite(color: 'red');
      final core = at(s, 0.05);
      expect(core[0], closeTo(0.0, 0.02), reason: 'no red at the core');
      expect(core[1], closeTo(1.0, 0.02));
      expect(core[2], closeTo(1.0, 0.02));
    });

    test('ramps cyan to white between 0.2 and 0.5', () {
      final s = fireworksSprite(color: 'red');
      final mid = at(s, 0.35);
      // Halfway: red climbing from 0 towards 1, green and blue already there.
      expect(mid[0], greaterThan(0.3));
      expect(mid[0], lessThan(0.8));
      expect(mid[1], closeTo(1.0, 0.02));
      expect(mid[2], closeTo(1.0, 0.02));
    });

    test('jumps discontinuously at 0.5 to the burst colour', () {
      // Two stops share offset 0.5. The earlier-added (white) applies up to it
      // and the later-added (the colour) from it, so the sprite has a hard ring.
      final s = fireworksSprite(color: 'red');
      final before = at(s, 0.44);
      final after = at(s, 0.56);
      expect(before[1], greaterThan(0.8), reason: 'white-ish before');
      expect(after[1], lessThan(0.3), reason: 'red has no green');
      expect(after[0], greaterThan(0.8));
    });

    test('fades to near-transparent at the rim, staying saturated', () {
      // Canvas interpolates gradients premultiplied, so the colour keeps its
      // hue while the alpha drops instead of turning muddy.
      final s = fireworksSprite(color: 'red');
      final rim = at(s, 0.98);
      expect(rim[3], lessThan(0.2), reason: 'alpha heads for 0.1');
      expect(rim[0], greaterThan(rim[1]), reason: 'still red, not grey');
    });

    test('the corners sit past the gradient and take the last stop', () {
      // The radius is half the canvas, so a corner is 1.41 radii out.
      final s = fireworksSprite(color: 'red');
      const i = 0; // (0, 0)
      expect(s.rgba[i + 3] / 255, closeTo(0.1, 0.02));
    });

    test('defaults to blue with no colour given', () {
      final s = fireworksSprite();
      final outer = at(s, 0.6);
      expect(outer[2], greaterThan(outer[0]));
      expect(outer[2], greaterThan(outer[1]));
    });

    test('CSS green is the dark one', () {
      // #008000, not #00FF00. Two of the ten bursts are that muted.
      final s = fireworksSprite(color: 'green');
      final outer = at(s, 0.55);
      expect(outer[1], greaterThan(0.3));
      expect(outer[1], lessThan(0.75), reason: 'not full-bright green');
      expect(outer[0], lessThan(0.2));
    });

    test('rejects a colour it does not know', () {
      expect(() => fireworksSprite(color: 'chartreuse'), throwsArgumentError);
    });
  });

  group('counts', () {
    test('numberRockets = 9 gives ten rockets', () async {
      expect(FireworksFilter.kNumberRockets, 9);
      expect(FireworksFilter.rocketCount, 10);
      final (f, _, _) = await build(particles: 4);
      expect(f.rockets.length, 10);
    });

    test('i <= 100 gives 101 particles per burst', () async {
      expect(FireworksFilter.kParticlesPerRocket, 101);
      final (f, _, _) = await build();
      expect(f.particles.length, 10 * 101);
    });

    test('there are ten colours, one per rocket, and they repeat', () {
      expect(FireworksFilter.kColors.length, 10);
      expect(FireworksFilter.kColors.where((c) => c == 'yellow').length, 3);
      expect(FireworksFilter.kColors.where((c) => c == 'red').length, 2);
      expect(FireworksFilter.kColors.where((c) => c == 'pink').length, 1);
    });

    test('particles of one rocket share one material', () async {
      final (f, _, _) = await build(particles: 5);
      final first = f.particles.first.material;
      for (var i = 0; i < 5; i++) {
        expect(identical(f.particles[i].material, first), isTrue);
      }
      // Rocket 0 is red and rocket 2 is green, so those differ.
      expect(identical(f.particles[10].material, first), isFalse);
      // Rocket 5 is red again, so it shares with rocket 0.
      expect(identical(f.particles[25].material, first), isTrue);
    });

    test('everything is additive and drawn last', () async {
      final (f, _, _) = await build(particles: 3);
      for (final s in [...f.rockets, ...f.particles]) {
        expect(s.material.blend, BlendMode.additive);
        expect(s.renderOrder, 100000);
      }
    });
  });

  group('the launch cycle', () {
    test('rockets start 1.2 s apart', () async {
      final (f, _, _) = await build(particles: 2);
      int flying() => f.rockets.where((r) => r.visible).length;

      expect(flying(), 0);
      advance(f, 0.1);
      expect(flying(), 1, reason: 'rocket 0 launches at t = 0');

      advance(f, 1.2); // 1.3 s: 0 and 1 both climbing
      expect(flying(), 2);

      // 2.5 s. Rocket 0 burst at 2.0 and is now reloading, so the count does
      // not keep climbing — 1 and 2 are up, 0 is gone.
      advance(f, 1.2);
      expect(flying(), 2);
      expect(f.rockets[0].visible, isFalse);
      expect(f.rockets[1].visible, isTrue);
      expect(f.rockets[2].visible, isTrue);
      expect(f.rockets[3].visible, isFalse, reason: 'launches at 3.6 s');
    });

    test('a rocket climbs from -4 to 1 over two seconds', () async {
      final (f, _, _) = await build(particles: 2);
      final r = f.rockets.first;

      advance(f, 0.05);
      expect(r.position.y, closeTo(-4.0, 0.3));
      advance(f, 0.95);
      expect(r.position.y, closeTo(-1.5, 0.3), reason: 'halfway, linearly');
      advance(f, 0.95);
      expect(r.position.y, closeTo(1.0, 0.3));
    });

    test('a rocket never launches from dead centre', () async {
      // `((random()*0.5) + 0.5) * ±1` — magnitude between 0.5 and 1.
      final (f, _, _) = await build(particles: 2, seed: 7);
      advance(f, 12.0);
      for (final r in f.rockets) {
        expect(r.position.x.abs(), greaterThanOrEqualTo(0.5));
        expect(r.position.x.abs(), lessThanOrEqualTo(1.0));
      }
    });

    test('the rocket hides at the top and the burst appears', () async {
      final (f, _, _) = await build(particles: 6);
      final r = f.rockets.first;
      final sparks = f.particles.take(6).toList();

      advance(f, 1.0);
      expect(r.visible, isTrue);
      expect(sparks.every((s) => !s.visible), isTrue);

      advance(f, 1.2); // past the two-second flight
      expect(r.visible, isFalse);
      expect(sparks.every((s) => s.visible), isTrue);
    });

    test('it relaunches three seconds after bursting', () async {
      final (f, _, _) = await build(particles: 2);
      final r = f.rockets.first;

      advance(f, 2.1);
      expect(r.visible, isFalse);
      advance(f, 2.0); // 4.1 s: still reloading
      expect(r.visible, isFalse);
      advance(f, 1.1); // 5.2 s: flying again
      expect(r.visible, isTrue);
      expect(r.position.y, lessThan(0));
    });
  });

  group('the burst', () {
    test('sparks start at the rocket and fan outward', () async {
      final (f, _, _) = await build(particles: 20, seed: 3);
      advance(f, 2.05);

      final rocketX = f.rockets.first.position.x;
      final sparks = f.particles.take(20).toList();
      // Just after the burst they are all still on the rocket.
      for (final s in sparks) {
        expect(s.position.x, closeTo(rocketX, 0.35));
        expect(s.position.y, closeTo(1.0, 0.35));
      }

      advance(f, 1.9);
      // And by the end they have spread.
      final xs = sparks.map((s) => s.position.x).toList();
      final spread = xs.reduce(math.max) - xs.reduce(math.min);
      expect(spread, greaterThan(0.5));
    });

    test('log10 of an angle makes a fan, not a circle', () async {
      // theta = log10(random()*2*PI) lands mostly in [0, 0.8] radians, so
      // sin(theta) is positive nearly always and the burst goes up, not
      // all around. A real angle would give a symmetric ring.
      final (f, _, _) = await build(particles: 60, seed: 11);
      advance(f, 4.0);

      final sparks = f.particles.take(60).toList();
      final ys = sparks.map((s) => s.position.y).toList();
      final above = ys.where((y) => y > 0).length;
      expect(above, greaterThan(45),
          reason: 'a symmetric ring would be about half; got $above of 60');
    });

    test('sparks shrink to nothing but are never hidden again', () async {
      final (f, _, _) = await build(particles: 8);
      advance(f, 2.05);
      final sparks = f.particles.take(8).toList();
      final startScales = sparks.map((s) => s.scale.x).toList();
      expect(startScales.every((s) => s > 0 && s <= 0.1), isTrue,
          reason: 'random()*0.1 overwrites the constructor\'s 3');

      advance(f, 2.5);
      for (final s in sparks) {
        expect(s.scale.x, closeTo(0.0001, 1e-6));
        expect(s.visible, isTrue, reason: 'nothing ever hides them');
      }
    });

    test('scale.z keeps the constructor\'s 3, which a Sprite ignores',
        () async {
      final (f, _, _) = await build(particles: 4);
      advance(f, 2.5);
      expect(f.particles.first.scale.z, 3.0);
    });

    test('sparks stay in the rocket\'s z plane', () async {
      // Only x and y are tweened.
      final (f, _, _) = await build(particles: 10, seed: 5);
      advance(f, 4.0);
      for (final s in f.particles.take(10)) {
        expect(s.position.z, 0.0);
      }
    });

    test('positions stay finite', () async {
      // log10 of a near-zero draw goes to -infinity, and cos/sin of that is
      // NaN. Guarded, because a NaN vertex poisons the rasteriser.
      for (var seed = 0; seed < 6; seed++) {
        final (f, _, _) = await build(particles: 30, seed: seed);
        advance(f, 9.0);
        for (final s in f.particles) {
          expect(s.position.x.isFinite, isTrue);
          expect(s.position.y.isFinite, isTrue);
          expect(s.scale.x.isFinite, isTrue);
        }
      }
    });
  });

  group('rendering', () {
    test('draws nothing before the first launch', () async {
      final (f, helper, cam) = await build(particles: 20);
      helper.update(const [head], cam);
      final fb = Framebuffer(240, 320);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('draws sparks once a rocket has burst', () async {
      final (f, helper, cam) = await build(particles: 40, seed: 2);
      advance(f, 2.3);
      helper.update(const [head], cam);
      final fb = Framebuffer(240, 320);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);

      var lit = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) lit++;
      }
      expect(lit, greaterThan(50));
    });

    test('an undetected face draws nothing', () async {
      final (f, helper, cam) = await build(particles: 20);
      advance(f, 3.0);
      helper.update(const [DetectState.lost], cam);
      final fb = Framebuffer(160, 240);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('the frame is a full-screen foreground', () async {
      final f = FireworksFilter(particlesPerRocket: 2);
      await f.load();
      expect(f.foreground, isNotNull);
      expect(f.foregroundLayout, ForegroundLayout.fill);
    });

    test('detach clears the scene', () async {
      final (f, helper, _) = await build(particles: 2);
      expect(helper.faceObject.children, isNotEmpty);
      f.detach(helper);
      expect(helper.faceObject.children, isEmpty);
      expect(f.rockets, isEmpty);
    });

    test('renders within a frame budget with all 1,010 sparks', () async {
      final (f, helper, cam) = await build();
      // Every rocket has burst by 12 s, so every particle is visible — the
      // worst case, and the state the demo settles into.
      advance(f, 13.0);

      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();
      for (var i = 0; i < 2; i++) {
        f.update(head, 1 / 30);
        helper.update(const [head], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }

      final sw = Stopwatch()..start();
      const frames = 5;
      for (var i = 0; i < frames; i++) {
        f.update(head, 1 / 30);
        helper.update(const [head], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // ignore: avoid_print
      print('fireworks: ${ms.toStringAsFixed(1)} ms/frame at 270x480 '
          '(${renderer.stats})');
      expect(ms, lessThan(600), reason: '${ms.toStringAsFixed(1)} ms/frame');
    });
  });

  group('determinism', () {
    test('a seed reproduces the same show', () async {
      final (a, _, _) = await build(particles: 10, seed: 42);
      final (b, _, _) = await build(particles: 10, seed: 42);
      advance(a, 7.0);
      advance(b, 7.0);
      for (var i = 0; i < a.particles.length; i++) {
        expect(a.particles[i].position.x, b.particles[i].position.x);
        expect(a.particles[i].position.y, b.particles[i].position.y);
      }
    });

    test('different seeds do not', () async {
      final (a, _, _) = await build(particles: 10, seed: 1);
      final (b, _, _) = await build(particles: 10, seed: 2);
      advance(a, 7.0);
      advance(b, 7.0);
      final same = <bool>[
        for (var i = 0; i < a.particles.length; i++)
          a.particles[i].position.x == b.particles[i].position.x,
      ];
      expect(same.every((s) => s), isFalse);
    });
  });
}
