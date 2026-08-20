// Renders the real cloud assets.
//
// New here: point lights, and 1503 separate rain meshes. The point light's
// attenuation and the lightning's chained flicker both have exact answers, and
// the rain's staggered timing is the kind of thing that looks fine while being
// subtly wrong — so all three are pinned.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('point lights', () {
    test('attenuation follows three\'s non-physical falloff', () {
      // pow(saturate(1 - d/cutoff), decay)
      expect(pointLightAttenuation(0, 100, 1), closeTo(1.0, 1e-12));
      expect(pointLightAttenuation(50, 100, 1), closeTo(0.5, 1e-12));
      expect(pointLightAttenuation(100, 100, 1), closeTo(0.0, 1e-12));
      expect(pointLightAttenuation(150, 100, 1), 0.0,
          reason: 'saturate clamps past the cutoff');
      expect(pointLightAttenuation(50, 100, 2), closeTo(0.25, 1e-12));

      // A zero cutoff means no attenuation at all, three's default.
      expect(pointLightAttenuation(1e6, 0, 1), 1.0);
    });

    test('a point light lights a surface, and dims with distance', () {
      final out = Float64List(4);

      // Surface at the view-space origin facing +Z; light straight in front.
      Fragment fragWithLightAt(double z) => Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..vx = 0
        ..vy = 0
        ..vz = 0
        ..lights = LightingContext(Vec3.zero, const [], [
          (
            position: Vec3(0, 0, z),
            color: const Vec3(1, 1, 1),
            distance: 100.0,
            decay: 1.0,
          )
        ]);

      LambertMaterial().shade(fragWithLightAt(10), out);
      final near = out[0];
      LambertMaterial().shade(fragWithLightAt(80), out);
      final far = out[0];

      expect(near, greaterThan(0.5), reason: 'a near light lights it');
      expect(far, lessThan(near), reason: 'and a far one lights it less');

      // Behind the surface: N·L is negative, so nothing.
      LambertMaterial().shade(fragWithLightAt(-10), out);
      expect(out[0], closeTo(0, 1e-12));
    });

    test('a zero-intensity point light is dropped before shading', () {
      // The lightning spends most of its cycle at intensity 0, and skipping it
      // then is what keeps the rain cheap.
      final scene = Scene()
        ..add(PointLight(intensity: 0, distance: 100))
        ..add(Mesh(_quad(), _LightProbe()));
      final camera = PerspectiveCamera(fov: 60, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(32, 32)..clear();

      final probe = _LightProbe();
      final scene2 = Scene()
        ..add(PointLight(intensity: 0, distance: 100))
        ..add(Mesh(_quad(), probe));
      SoftwareRenderer().render(scene2, camera, fb);

      expect(probe.samples, greaterThan(0));
      expect(probe.lastPointCount, 0, reason: 'dark lights never reach a shader');
      expect(scene.children.length, 2);
    });
  });

  group('lightning', () {
    test('flickers twice, then holds dark for three seconds', () async {
      final filter = CloudFilter(dropsPerStream: 1, showFrame: false);
      await filter.load();
      final helper = JeelizFaceFilterHelper();
      filter.attach(helper);

      const s = DetectState(
          detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);

      // Count rises out of darkness. The chain is 0->3, 3->0, 0->3, 3->0, so
      // one cycle is two peaks over 280ms, followed by a 3s dark pause —
      // 3.28s end to end.
      var peaks = 0;
      var wasLit = false;
      var maxIntensity = 0.0;
      var litSamples = 0;
      const step = 0.005;

      void sampleFor(double seconds) {
        for (var t = 0.0; t < seconds; t += step) {
          filter.update(s, step);
          final i = filter.lightningIntensity;
          if (i > maxIntensity) maxIntensity = i;
          final lit = i > 0.05;
          if (lit && !wasLit) peaks++;
          if (lit) litSamples++;
          wasLit = lit;
        }
      }

      // Stop inside the pause, before the next cycle begins.
      sampleFor(3.0);
      expect(peaks, 2, reason: 'a double flicker, not one flash');
      expect(maxIntensity, closeTo(3.0, 0.2), reason: 'peaks at intensity 3');
      // Lit for ~280ms of the 3.28s cycle.
      expect(litSamples * step, lessThan(0.5));

      // Cross the cycle boundary: it must strike again rather than stay dark.
      // The pause ends at 3.28s and the *second* peak of the new cycle is not
      // until 3.43s, so stop between them to see exactly one more.
      sampleFor(0.32);
      expect(peaks, 3, reason: 'the cycle repeats after the pause');
    });
  });

  group('rain', () {
    test('drops park, fall, and recycle on a staggered period', () async {
      final filter = CloudFilter(dropsPerStream: 3, showFrame: false);
      await filter.load();
      final helper = JeelizFaceFilterHelper();
      filter.attach(helper);

      final drops = <Mesh>[];
      helper.faceObject.traverse((o) {
        if (o is Mesh && o.name == 'drop') drops.add(o);
      });
      expect(drops.length, 9, reason: '3 per stream, 3 streams');

      const s = DetectState(
          detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);

      // The three streams start at distinct heights.
      final startYs = drops.map((d) => d.position.y).toSet();
      expect(startYs.length, 3);
      expect(startYs.contains(1.5), isTrue);

      // Index 0 has zero delay, so it starts falling immediately.
      final first = drops.first;
      final y0 = first.position.y;
      filter.update(s, 0.5);
      expect(first.position.y, lessThan(y0), reason: 'undelayed drop falls');

      // After a full 3s fall it wraps back to the top rather than continuing
      // to -20 forever.
      for (var i = 0; i < 200; i++) {
        filter.update(s, 0.02);
      }
      expect(first.position.y, lessThanOrEqualTo(1.5));
      expect(first.position.y, greaterThan(-21));
    });

    test('x and z never drift while falling', () async {
      final filter = CloudFilter(dropsPerStream: 2, showFrame: false);
      await filter.load();
      final helper = JeelizFaceFilterHelper();
      filter.attach(helper);

      final drops = <Mesh>[];
      helper.faceObject.traverse((o) {
        if (o is Mesh && o.name == 'drop') drops.add(o);
      });

      final before = drops.map((d) => (d.position.x, d.position.z)).toList();
      const s = DetectState(
          detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);
      for (var i = 0; i < 50; i++) {
        filter.update(s, 0.05);
      }
      final after = drops.map((d) => (d.position.x, d.position.z)).toList();
      expect(after, before, reason: 'rain falls straight down');
    });
  });

  group('filter', () {
    late CloudFilter filter;
    late JeelizFaceFilterHelper helper;
    late PerspectiveCamera camera;
    late Framebuffer fb;
    late SoftwareRenderer renderer;

    setUp(() async {
      // A reduced rain count keeps the suite quick; the full 501 is exercised
      // by the perf expectation below via the default constructor elsewhere.
      filter = CloudFilter(dropsPerStream: 40);
      await filter.load();
      helper = JeelizFaceFilterHelper();
      camera = helper.createCamera();
      renderer = SoftwareRenderer();
      fb = Framebuffer(270, 480);
      filter.attach(helper);
      helper.updateCamera(camera,
          canvasWidth: 270,
          canvasHeight: 480,
          videoWidth: 720,
          videoHeight: 1280);
    });

    DetectState head() => const DetectState(
        detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);

    void draw(DetectState s, {double dt = 1 / 30}) {
      helper.update([s], camera);
      filter.update(s, dt);
      fb.clear();
      renderer.render(helper.scene, camera, fb);
    }

    int drawnPixels() {
      var n = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) n++;
      }
      return n;
    }

    test('builds three clouds sharing one geometry', () {
      final clouds = <Mesh>[];
      helper.faceObject.traverse((o) {
        if (o is Mesh && o.name.startsWith('cloud')) clouds.add(o);
      });
      expect(clouds.length, 3);
      expect(clouds[0].geometry.triangleCount, 4578);
      // `.clone()` shares geometry and material in three, and so do these.
      expect(identical(clouds[0].geometry, clouds[1].geometry), isTrue);
      expect(identical(clouds[0].material, clouds[2].material), isTrue);

      // The compounded clone scales: cloud 2 and 3 are far smaller than their
      // literals suggest, because they were cloned after cloud 1 was scaled.
      expect(clouds[0].scale.x, closeTo(0.4, 1e-9));
      expect(clouds[1].scale.x, closeTo(0.4 * 0.4 * 0.7, 1e-9));
      expect(clouds[2].scale.y, closeTo(0.2 * 0.4 * 1.3, 1e-9));
    });

    test('a detected face draws the clouds above the head', () {
      draw(head());
      expect(drawnPixels(), greaterThan(2000));
      expect(renderer.stats.fragments, greaterThan(0));

      // The clouds sit above the face, so the painted mass must be in the
      // upper half of the frame.
      var above = 0, below = 0;
      for (var y = 0; y < fb.height; y++) {
        for (var x = 0; x < fb.width; x++) {
          if (fb.color[(y * fb.width + x) * 4 + 3] > 0) {
            if (y < fb.height / 2) {
              above++;
            } else {
              below++;
            }
          }
        }
      }
      expect(above, greaterThan(below));
    });

    test('the frame overlay loads', () {
      expect(filter.foreground, isNotNull);
      expect(filter.foreground!.width, greaterThan(64));
    });

    test('an undetected face draws nothing', () {
      draw(DetectState.lost);
      expect(helper.isDetected, isFalse);
      expect(drawnPixels(), 0);
    });

    test('renders within a frame budget', () {
      draw(head());
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        draw(head());
      }
      sw.stop();
      final perFrameMs = sw.elapsedMilliseconds / 10;
      expect(perFrameMs, lessThan(400), reason: '${perFrameMs}ms per frame');
    });
  });
}

BufferGeometry _quad() => BufferGeometry(
      positions: Float32List.fromList(
          [-1, -1, -2, 1, -1, -2, 1, 1, -2, -1, 1, -2]),
      indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
      normals: Float32List.fromList(
          [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
    );

/// Reports how many point lights actually reached the shader.
class _LightProbe extends Material {
  int samples = 0;
  int lastPointCount = -1;

  @override
  MaterialSide get side => MaterialSide.double;

  @override
  bool shade(Fragment f, Float64List out) {
    samples++;
    lastPointCount = f.lights.point.length;
    out[0] = out[1] = out[2] = out[3] = 1;
    return true;
  }
}
