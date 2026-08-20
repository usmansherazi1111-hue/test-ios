// Tests for demos/threejs/butterflies.
//
// Most of this filter is animation, so most of these tests are about *time*:
// when a butterfly appears, where it is on its orbit, which morph frames are
// blended, and where its light is in the tween chain. Several also pin the
// demo's oddities as intentional, because each one reads like a mistake and
// "fixing" any of them would change the swarm.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

// Plain `test`, not `testWidgets`: this filter decodes six JPEGs at load, and
// `testWidgets` runs the body inside FakeAsync, where `instantiateImageCodec`
// never completes. tiger_test.dart is set up the same way for the same reason.

/// Attaches a loaded filter to a fresh helper and returns both.
Future<(ButterfliesFilter, JeelizFaceFilterHelper, PerspectiveCamera)> setUp$({
  bool grass = false,
}) async {
  final filter = ButterfliesFilter(showGrass: grass, textureMaxWidth: 64);
  await filter.load();
  final helper = JeelizFaceFilterHelper();
  final camera = helper.createCamera();
  helper.updateCamera(camera,
      canvasWidth: 240, canvasHeight: 320, videoWidth: 240, videoHeight: 320);
  filter.attach(helper);
  return (filter, helper, camera);
}

/// Runs the filter forward in [dt] steps until [seconds] have elapsed.
void advance(ButterfliesFilter f, double seconds, {double dt = 1 / 30}) {
  const state = DetectState(
      detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
  var t = 0.0;
  while (t < seconds) {
    f.update(state, dt);
    t += dt;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the swarm', () {
    test('is nine butterflies, not ten', () async {
      // `for (let i = 2; i <= NUMBERBUTTERFLIES; i++)` with
      // NUMBERBUTTERFLIES = 10 runs i = 2..10.
      expect(ButterfliesFilter.kNumberButterflies, 10);
      expect(ButterfliesFilter.kFirstIndex, 2);
      expect(ButterfliesFilter.count, 9);

      final (f, _, _) = await setUp$();
      expect(f.meshes.length, 9);
      expect(f.lights.length, 9);
    });

    test('shares one geometry and one morph set across all nine',
        () async {
      final (f, _, _) = await setUp$();
      final first = f.meshes.first.geometry;
      for (final m in f.meshes) {
        expect(identical(m.geometry, first), isTrue,
            reason: '106 morph frames must not be copied nine times');
      }
      expect(first.morphPositions.length, 106);
      // 332 quads + 28 triangles = 692 triangles, de-indexed to corners.
      expect(first.morphPositions.first.length, first.positions.length);
    });

    test('cycles five wing textures, with 1 used twice and 5 once',
        () async {
      // indexTexture = i % 6 === 0 ? 1 : i % 6, over i = 2..10:
      //   2,3,4,5,1,1,2,3,4
      final wanted = <int>[2, 3, 4, 5, 1, 1, 2, 3, 4];
      final (f, _, _) = await setUp$();

      // Distinct texture objects per index, so identity groups them.
      final maps = f.meshes
          .map((m) => (m.materials.first as LambertMaterial).map)
          .toList();
      final ids = <Object, int>{};
      final got = <int>[];
      for (final m in maps) {
        got.add(ids.putIfAbsent(m!, () => ids.length));
      }

      // Compare the *grouping*, not the raw numbering.
      String shape(List<int> xs) {
        final seen = <int, int>{};
        return xs.map((x) => seen.putIfAbsent(x, () => seen.length)).join();
      }

      expect(shape(got), shape(wanted));
      expect(ids.length, 5, reason: 'five distinct diffuse maps');
    });

    test('every butterfly shares the one alpha map', () async {
      final (f, _, _) = await setUp$();
      final alpha = (f.meshes.first.materials.first as LambertMaterial).alphaMap;
      expect(alpha, isNotNull);
      for (final m in f.meshes) {
        expect(
            identical((m.materials.first as LambertMaterial).alphaMap, alpha),
            isTrue);
      }
    });

    test('the geometry carries no material index, so there is no body',
        () async {
      // butterfly.json's face stream never sets bit 1, so every face is
      // material 0 and the demo's second material is dead. If a group ever
      // referenced index 1 the port would need it.
      final (f, _, _) = await setUp$();
      final g = f.meshes.first.geometry;
      for (final group in g.groups) {
        expect(group.materialIndex, 0);
      }
      expect(f.meshes.first.materials.length, 1);
    });
  });

  group('spawning', () {
    test('butterflies appear one at a time, 600 ms apart',
        () async {
      final (f, _, _) = await setUp$();

      int visible() => f.meshes.where((m) => m.visible).length;

      // Nothing before the first timeout at 600*2 = 1.2 s.
      expect(visible(), 0);
      advance(f, 1.0);
      expect(visible(), 0);

      // i = 2 at 1.2 s.
      advance(f, 0.35);
      expect(visible(), 1);

      // i = 3 at 1.8 s.
      advance(f, 0.6);
      expect(visible(), 2);

      // All nine by 600*10 = 6.0 s.
      advance(f, 5.0);
      expect(visible(), 9);
    });

    test('an unspawned butterfly is transparent as well as hidden',
        () async {
      // `opacity: 0` on a material that *is* transparent, unlike the body's.
      final (f, _, _) = await setUp$();
      final mats = f.meshes
          .map((m) => m.materials.first as LambertMaterial)
          .toList();
      expect(mats.every((m) => m.transparent), isTrue);
      expect(mats.every((m) => m.opacity == 0.0), isTrue);

      advance(f, 1.3);
      expect(mats.first.opacity, 1.0);
      expect(mats.last.opacity, 0.0);
    });

    test('a butterfly does not start flying before it appears',
        () async {
      final (f, _, _) = await setUp$();
      final last = f.meshes.last;
      final at0 = last.position;
      advance(f, 3.0);
      expect(last.position.x, at0.x, reason: 'still waiting its turn');
      expect(last.visible, isFalse);
    });
  });

  group('the flight path', () {
    test('is an ellipse in XZ with a slow vertical bob',
        () async {
      final (f, _, _) = await setUp$();
      advance(f, 7.0);

      final m = f.meshes.first;
      final samples = <Vec3>[];
      for (var i = 0; i < 200; i++) {
        advance(f, 0.1);
        samples.add(m.position);
      }

      final xs = samples.map((p) => p.x).toList();
      final ys = samples.map((p) => p.y).toList();
      final zs = samples.map((p) => p.z).toList();

      // X and Z swing symmetrically about zero; Y bobs about +1.
      expect(xs.reduce(math.max), greaterThan(0));
      expect(xs.reduce(math.min), lessThan(0));
      expect(zs.reduce(math.max), greaterThan(0));
      expect(zs.reduce(math.min), lessThan(0));
      final meanY = ys.reduce((a, b) => a + b) / ys.length;
      expect(meanY, closeTo(1.0, 0.6));

      // The vertical rate is 0.2*index against 1.0 for the orbit, so Y varies
      // far less over a given span than X does.
      final spanX = xs.reduce(math.max) - xs.reduce(math.min);
      final spanY = ys.reduce(math.max) - ys.reduce(math.min);
      expect(spanY, lessThan(spanX));
    });

    test('the light rides with its butterfly', () async {
      // The demo calls animateFly on the mesh and on the light separately,
      // from the same origin and index; here one evaluation drives both.
      final (f, _, _) = await setUp$();
      advance(f, 8.0);
      for (var i = 0; i < f.meshes.length; i++) {
        if (!f.meshes[i].visible) continue;
        expect(f.lights[i].position.x, f.meshes[i].position.x);
        expect(f.lights[i].position.y, f.meshes[i].position.y);
        expect(f.lights[i].position.z, f.meshes[i].position.z);
      }
    });

    test('the nine orbits are out of phase with each other',
        () async {
      // Different random radii and different vertical rates, so at any instant
      // no two butterflies sit in the same place.
      final (f, _, _) = await setUp$();
      advance(f, 12.0);
      final live = [
        for (var i = 0; i < f.meshes.length; i++)
          if (f.meshes[i].visible) f.meshes[i].position,
      ];
      expect(live.length, 9);
      for (var a = 0; a < live.length; a++) {
        for (var b = a + 1; b < live.length; b++) {
          final d = (live[a].x - live[b].x).abs() +
              (live[a].y - live[b].y).abs() +
              (live[a].z - live[b].z).abs();
          expect(d, greaterThan(1e-6));
        }
      }
    });

    test('yaw sweeps and roll rocks, pitch stays put', () async {
      // rotation.y = 1.5*cos(count+0.05) + 0.3, rotation.z = 0.2*sin(count),
      // rotation.x untouched.
      final (f, _, _) = await setUp$();
      advance(f, 7.0);
      final m = f.meshes.first;

      var minY = double.infinity, maxY = -double.infinity;
      var minZ = double.infinity, maxZ = -double.infinity;
      for (var i = 0; i < 400; i++) {
        advance(f, 0.1);
        minY = math.min(minY, m.rotation.y);
        maxY = math.max(maxY, m.rotation.y);
        minZ = math.min(minZ, m.rotation.z);
        maxZ = math.max(maxZ, m.rotation.z);
        expect(m.rotation.x, 0.0);
      }
      // Amplitude 1.5 about +0.3, and 0.2 about 0.
      expect(maxY, closeTo(1.8, 0.05));
      expect(minY, closeTo(-1.2, 0.05));
      expect(maxZ, closeTo(0.2, 0.02));
      expect(minZ, closeTo(-0.2, 0.02));
    });

    test('the random start sets the orbit radii, not the position',
        () async {
      // At count = 0 the first tick puts every butterfly at (x+k, 1, 0)
      // regardless of its random y and z — those only survive as radii.
      final a = ButterfliesFilter(showGrass: false, textureMaxWidth: 64,
          randomSeed: 1);
      final b = ButterfliesFilter(showGrass: false, textureMaxWidth: 64,
          randomSeed: 2);
      await a.load();
      await b.load();
      final ha = JeelizFaceFilterHelper(), hb = JeelizFaceFilterHelper();
      a.attach(ha);
      b.attach(hb);

      advance(a, 20.0);
      advance(b, 20.0);
      expect(a.meshes.first.position.x, isNot(b.meshes.first.position.x),
          reason: 'different seeds must give different orbits');
    });
  });

  group('the wing flap', () {
    test('blends exactly two adjacent morph frames, summing to one',
        () async {
      final (f, _, _) = await setUp$();
      advance(f, 5.0);

      for (final m in f.meshes) {
        if (!m.visible) continue;
        final nz = <int>[];
        var total = 0.0;
        for (var i = 0; i < m.morphInfluences.length; i++) {
          final w = m.morphInfluences[i];
          if (w != 0) {
            nz.add(i);
            total += w;
          }
        }
        expect(nz.length, inInclusiveRange(1, 2));
        expect(total, closeTo(1.0, 1e-9));
        if (nz.length == 2) {
          expect((nz[1] - nz[0]) % 106, anyOf(1, 105),
              reason: 'adjacent, wrapping at the end of the clip');
        }
      }
    });

    test('runs at 10 fps over 106 frames, so a cycle is 10.6 s',
        () async {
      expect(ButterfliesFilter.kMorphFps, 10.0);
      final (f, _, _) = await setUp$();
      advance(f, 1.3); // first butterfly alive

      int frameOf(Mesh m) {
        var best = -1;
        var bestW = 0.0;
        for (var i = 0; i < m.morphInfluences.length; i++) {
          if (m.morphInfluences[i] > bestW) {
            bestW = m.morphInfluences[i];
            best = i;
          }
        }
        return best;
      }

      final m = f.meshes.first;
      final start = frameOf(m);
      // The fixed 0.13 s step advances 1.3 clip frames per update, so ~82
      // updates return to the start.
      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
      for (var i = 0; i < 82; i++) {
        f.update(state, 1 / 30);
      }
      expect((frameOf(m) - start).abs() % 106, lessThan(3),
          reason: 'one full 106-frame cycle in ~82 fixed steps');
    });

    test('the fixed 0.13 step ignores real dt, as the demo does',
        () async {
      // `m.update(0.13)` inside callbackTrack — the wings advance per frame,
      // not per second. Two runs with different dt but the same frame count
      // must land on the same wing frame.
      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
      expect(ButterfliesFilter.kWingStepSeconds, 0.13);

      final slow = ButterfliesFilter(showGrass: false, textureMaxWidth: 64);
      final fast = ButterfliesFilter(showGrass: false, textureMaxWidth: 64);
      await slow.load();
      await fast.load();
      slow.attach(JeelizFaceFilterHelper());
      fast.attach(JeelizFaceFilterHelper());

      // Get both past the first spawn with the same number of updates.
      for (var i = 0; i < 40; i++) {
        slow.update(state, 0.1);
        fast.update(state, 0.1);
      }
      for (var i = 0; i < 25; i++) {
        slow.update(state, 1 / 15);
        fast.update(state, 1 / 60);
      }
      expect(slow.meshes.first.morphInfluences,
          fast.meshes.first.morphInfluences,
          reason: 'same frame count, same wing phase, whatever the clock said');
    });

    test('wingStepSeconds = null switches to real time', () async {
      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
      final f = ButterfliesFilter(showGrass: false, textureMaxWidth: 64)
        ..wingStepSeconds = null;
      await f.load();
      f.attach(JeelizFaceFilterHelper());
      for (var i = 0; i < 40; i++) {
        f.update(state, 0.1);
      }
      final before = List<double>.from(f.meshes.first.morphInfluences);
      f.update(state, 0.0);
      expect(f.meshes.first.morphInfluences, before,
          reason: 'a zero-length frame must not advance the wings');
    });

    test('the nine flaps are staggered', () async {
      expect(ButterfliesFilter.kWingPhaseStagger, closeTo(0.033, 1e-9));
      final (f, _, _) = await setUp$();
      advance(f, 7.0);
      final phases = f.meshes
          .map((m) => m.morphInfluences.indexWhere((w) => w > 0))
          .toSet();
      expect(phases.length, greaterThan(1),
          reason: 'they must not all beat in unison');
    });
  });

  group('the point lights', () {
    test('are cyan, with the demo\'s distance and decay',
        () async {
      final (f, _, _) = await setUp$();
      for (final l in f.lights) {
        expect(l.color.x, closeTo(0x77 / 255, 1e-9));
        expect(l.color.y, 1.0);
        expect(l.color.z, 1.0);
        expect(l.distance, 1.0);
        expect(l.decay, 0.1);
      }
    });

    test('open at 1 and ramp down to 0.6, then oscillate 0..0.6',
        () async {
      final (f, _, _) = await setUp$();
      final light = f.lights.first;

      // Constructed at 1, and the first tween runs 1 -> 0.6 over 2 s.
      expect(light.intensity, 1.0);
      advance(f, 1.25); // just spawned
      expect(light.intensity, closeTo(1.0, 0.05));

      advance(f, 1.0); // 1 s into the opening ramp
      expect(light.intensity, closeTo(0.8, 0.05));

      advance(f, 1.05); // opening ramp done
      expect(light.intensity, closeTo(0.6, 0.05));

      // Then down to 0 over 2 s.
      advance(f, 2.0);
      expect(light.intensity, closeTo(0.0, 0.05));

      // And back up to 0.6 — never to 1 again.
      advance(f, 2.0);
      expect(light.intensity, closeTo(0.6, 0.05));
    });

    test('intensity never leaves [0, 1]', () async {
      final (f, _, _) = await setUp$();
      for (var i = 0; i < 400; i++) {
        advance(f, 0.1);
        for (final l in f.lights) {
          expect(l.intensity, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('decay 0.1 keeps the light near full until the cutoff',
        () async {
      // pow(1 - d/1, 0.1) is very flat: still 87% of full at half the cutoff,
      // then it collapses.
      expect(pointLightAttenuation(0.0, 1.0, 0.1), closeTo(1.0, 1e-9));
      expect(pointLightAttenuation(0.5, 1.0, 0.1), greaterThan(0.9));
      expect(pointLightAttenuation(0.99, 1.0, 0.1), greaterThan(0.5));
      expect(pointLightAttenuation(1.0, 1.0, 0.1), 0.0);
    });

    test('there is no other light in the scene', () async {
      // The whole look depends on this: nothing but the nine point lights, so
      // a butterfly at the bottom of its tween goes black rather than
      // disappearing.
      final (f, helper, _) = await setUp$();
      var ambient = 0, directional = 0, point = 0;
      void walk(Object3D o) {
        if (o is AmbientLight) ambient++;
        if (o is DirectionalLight) directional++;
        if (o is PointLight) point++;
        for (final c in o.children) {
          walk(c);
        }
      }

      walk(helper.scene);
      expect(ambient, 0);
      expect(directional, 0);
      expect(point, 9);
    });
  });

  group('the grass', () {
    test('is a bottom-anchored foreground, not a full-screen quad',
        () async {
      // Its stylesheet is `width: 100vmin; bottom: -5px; left: 50%;
      // translateX(-50%)` — a 1600x227 strip. Stretching it to fill would
      // smear it over the whole screen.
      final f = ButterfliesFilter(textureMaxWidth: 64);
      await f.load();
      expect(f.foreground, isNotNull);
      expect(f.foregroundLayout, ForegroundLayout.bottomVmin);
    });

    test('can be turned off', () async {
      final (f, _, _) = await setUp$();
      expect(f.foreground, isNull);
    });
  });

  group('rendering', () {
    test('draws the swarm once it has arrived', () async {
      final (f, helper, camera) = await setUp$();
      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);

      final fb = Framebuffer(240, 320);
      final renderer = SoftwareRenderer();

      // Before any spawn: nothing to see.
      helper.update(const [state], camera);
      fb.clear();
      renderer.render(helper.scene, camera, fb);
      var covered = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) covered++;
      }
      expect(covered, 0);

      advance(f, 7.0);
      helper.update(const [state], camera);
      fb.clear();
      renderer.render(helper.scene, camera, fb);

      covered = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) covered++;
      }
      expect(covered, greaterThan(200),
          reason: 'nine butterflies should be somewhere on screen');
    });

    test('an undetected face draws nothing', () async {
      final (f, helper, camera) = await setUp$();
      advance(f, 7.0);
      helper.update(const [DetectState.lost], camera);
      final fb = Framebuffer(160, 200);
      fb.clear();
      SoftwareRenderer().render(helper.scene, camera, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('renders within a frame budget', () async {
      final (f, helper, camera) = await setUp$();
      advance(f, 7.0);

      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();

      for (var i = 0; i < 2; i++) {
        f.update(state, 1 / 30);
        helper.update(const [state], camera);
        fb.clear();
        renderer.render(helper.scene, camera, fb);
      }

      final sw = Stopwatch()..start();
      const frames = 5;
      for (var i = 0; i < frames; i++) {
        f.update(state, 1 / 30);
        helper.update(const [state], camera);
        fb.clear();
        renderer.render(helper.scene, camera, fb);
      }
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // ignore: avoid_print
      print('butterflies: ${ms.toStringAsFixed(1)} ms/frame at 270x480 '
          '(${renderer.stats})');
      expect(ms, lessThan(600), reason: '${ms.toStringAsFixed(1)} ms/frame');
    });
  });
}
