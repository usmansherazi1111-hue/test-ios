// Renders the real dog_face assets.
//
// This filter brought four new subsystems, and every one of them fails quietly
// rather than loudly: a packed face stream mis-strided still parses into
// *some* geometry, morph influences that do not sum to 1 still render, a
// transposed bump basis still looks bumpy, and a flex material whose lagged
// matrix is wrong just looks stiff. So each gets pinned against a case with a
// known answer.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('legacy Geometry loader', () {
    test('walks a hand-built packed face stream', () {
      // Two records with different strides, which is the whole difficulty: a
      // triangle with no extras, then a quad with per-vertex UVs.
      //   type 0  = triangle, nothing else
      //   type 9  = 1|8 = quad + per-vertex UV
      final g = parseLegacyGeometryJson(const {
        'metadata': {'type': 'Geometry'},
        'vertices': [
          0, 0, 0, //
          1, 0, 0, //
          1, 1, 0, //
          0, 1, 0, //
          2, 0, 0,
        ],
        'uvs': [
          [0, 0, 1, 0, 1, 1, 0, 1]
        ],
        'faces': [
          0, 0, 1, 4, // triangle over verts 0,1,4 — no extras
          9, 0, 1, 2, 3, 0, 1, 2, 3, // quad over 0,1,2,3 with uv 0,1,2,3
        ],
      });

      // 1 triangle + 1 quad(=2 triangles) = 3 triangles, de-indexed to 9 verts.
      expect(g.geometry.triangleCount, 3);
      expect(g.geometry.vertexCount, 9);

      // First corner of the first face is vertex 0 at the origin.
      expect(g.geometry.positions[0], 0);
      expect(g.geometry.positions[1], 0);
      // Third corner of the first face is vertex 4 at (2,0,0) — proof the
      // triangle record consumed exactly 3 indices and no more.
      expect(g.geometry.positions[6], 2);

      // The stream mixes a record without UVs and one with. The absent corners
      // must be zero-padded rather than skipped, or every later vertex's UV
      // would be shifted — which still parses and still renders, just wrongly.
      expect(g.geometry.uvs, isNotNull);
      expect(g.geometry.uvs!.length, g.geometry.vertexCount * 2);
      // First three corners (the UV-less triangle) padded to zero...
      expect(g.geometry.uvs!.sublist(0, 6), everyElement(0.0));
      // ...and the quad's first corner carries uv index 0 = (0, 0), its second
      // uv index 1 = (1, 0).
      expect(g.geometry.uvs![8], 1.0);
    });

    test('parses dog_tongue.json with all 26 morph frames', () async {
      final g = decodeLegacyGeometry(
          await loadJeelizAssetString('dogFace/dog_tongue.json'));

      // 392 quads -> 784 triangles -> 2352 de-indexed corners.
      expect(g.geometry.triangleCount, 784);
      expect(g.geometry.vertexCount, 2352);
      expect(g.geometry.uvs!.length, 2352 * 2);
      expect(g.morphFrames.length, 26);
      expect(g.morphNames.first, 'animation_000000');

      // Every frame must be de-indexed to the same length as the base mesh, or
      // the vertex stage would read past the end.
      for (final f in g.morphFrames) {
        expect(f.length, g.geometry.positions.length);
      }

      // And the frames must actually differ, or there is no animation.
      var maxDelta = 0.0;
      final base = g.morphFrames.first;
      for (final f in g.morphFrames) {
        for (var i = 0; i < f.length; i++) {
          final d = (f[i] - base[i]).abs();
          if (d > maxDelta) maxDelta = d;
        }
      }
      expect(maxDelta, greaterThan(0.05));
    });
  });

  group('morph targets', () {
    test('influences blend frames into the base mesh', () {
      // One triangle, one morph frame that shifts it 10 units in +Y.
      // Keep the morphed pose inside the frustum, or it simply does not
      // rasterise and the probe sees nothing.
      final base = Float32List.fromList([0, 0, -2, 1, 0, -2, 0, 1, -2]);
      final frame = Float32List.fromList([0, 1, -2, 1, 1, -2, 0, 2, -2]);

      final geom = BufferGeometry(
        positions: base,
        indices: Uint32List.fromList([0, 1, 2]),
        normals: Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
        morphPositions: [frame],
      );

      final probe = _PositionProbe();
      final mesh = Mesh(geom, probe);
      final scene = Scene()..add(mesh);
      final camera = PerspectiveCamera(fov: 90, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(64, 64);
      final renderer = SoftwareRenderer();

      // Influence 0: the triangle sits at the bottom of the frame.
      mesh.morphInfluences = [0.0];
      fb.clear();
      probe.reset();
      renderer.render(scene, camera, fb);
      final atRest = probe.meanViewY;

      // Influence 1: fully morphed, so it moves up.
      mesh.morphInfluences = [1.0];
      fb.clear();
      probe.reset();
      renderer.render(scene, camera, fb);
      final morphed = probe.meanViewY;

      expect(probe.samples, greaterThan(0));
      expect(morphed, greaterThan(atRest + 0.5),
          reason: 'a full influence must apply the whole frame delta');
    });
  });

  group('bump mapping', () {
    test('a flat bump map leaves the normal alone', () {
      // Constant height everywhere => zero gradient => no perturbation.
      final flat = Texture2D.solid(128, 128, 128);
      final mat = PhongMaterial(bumpMap: flat, bumpScale: 1.0);
      expect(mat.needsScreenDerivatives, isTrue);

      final out = Float64List(4);
      final f = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..vz = -1
        // A well-formed screen basis, so fDet is non-degenerate.
        ..pdxX = 1
        ..pdyY = 1
        ..dudx = 0.01
        ..dvdy = 0.01
        ..lights = LightingContext(
            const Vec3(1, 1, 1), [(direction: const Vec3(0, 0, 1), color: const Vec3(1, 1, 1))]);

      expect(mat.shade(f, out), isTrue);
      // With a flat map the shading must match the no-bump case exactly.
      final plain = Float64List(4);
      PhongMaterial().shade(f, plain);
      expect(out[0], closeTo(plain[0], 1e-9));
    });

    test('a bump gradient tilts the normal and changes shading', () {
      // A horizontal ramp, so du sampling finds a height difference.
      const w = 32;
      final px = Uint8List(w * w * 4);
      for (var y = 0; y < w; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final h = 255 * x ~/ (w - 1);
          px[i] = h;
          px[i + 1] = h;
          px[i + 2] = h;
          px[i + 3] = 255;
        }
      }
      final ramp = Texture2D(w, w, px);

      final out = Float64List(4);
      Fragment frag() => Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..vz = -1
        ..u = 0.5
        ..v = 0.5
        ..pdxX = 1
        ..pdyY = 1
        ..dudx = 0.2
        ..dvdy = 0.2
        ..lights = LightingContext(Vec3.zero,
            [(direction: const Vec3(0.7, 0, 0.7), color: const Vec3(1, 1, 1))]);

      PhongMaterial(bumpScale: 0).shade(frag(), out);
      final unbumped = out[0];
      PhongMaterial(bumpMap: ramp, bumpScale: 2.0).shade(frag(), out);
      final bumped = out[0];

      expect((bumped - unbumped).abs(), greaterThan(1e-3),
          reason: 'a real height gradient must change the lighting');
    });
  });

  group('FlexMaterial', () {
    test('lags behind a moving target, then catches up when it stops', () {
      final mat = FlexMaterial(flexMap: Texture2D.solid(255, 255, 255));
      final out = Float64List(3);

      // A vertex at the origin, so world position is just the translation.
      final far = Mat4.compose(
          const Vec3(10, 0, 0), Euler.zero, Vec3.one);

      // First call snaps: no lag yet.
      mat.setAmortized(
          position: const Vec3(10, 0, 0),
          scale: Vec3.one,
          euler: Vec3.zero,
          amortization: 0.1);
      mat.worldPosition(0, 0, 0, 0.5, 0.5, far, out);
      expect(out[0], closeTo(10, 1e-9),
          reason: 'the first frame must not ease in from the origin');

      // Now jump the target. flexMap is white, so the vertex follows the
      // *lagged* matrix entirely and must trail behind.
      final moved = Mat4.compose(const Vec3(0, 0, 0), Euler.zero, Vec3.one);
      mat.setAmortized(
          position: Vec3.zero,
          scale: Vec3.one,
          euler: Vec3.zero,
          amortization: 0.1);
      mat.worldPosition(0, 0, 0, 0.5, 0.5, moved, out);
      expect(out[0], greaterThan(5),
          reason: 'lagged matrix has only moved 10% of the way');

      // Hold still and it converges.
      for (var i = 0; i < 200; i++) {
        mat.setAmortized(
            position: Vec3.zero,
            scale: Vec3.one,
            euler: Vec3.zero,
            amortization: 0.1);
      }
      mat.worldPosition(0, 0, 0, 0.5, 0.5, moved, out);
      expect(out[0], closeTo(0, 1e-3));
    });

    test('flexMap black welds the vertex to the real matrix', () {
      final mat = FlexMaterial(flexMap: Texture2D.solid(0, 0, 0));
      final out = Float64List(3);
      final model = Mat4.compose(const Vec3(3, 4, 5), Euler.zero, Vec3.one);

      // Deliberately stale lagged state, which must be ignored entirely.
      mat.setAmortized(
          position: const Vec3(-100, -100, -100),
          scale: Vec3.one,
          euler: Vec3.zero,
          amortization: 1.0);

      mat.worldPosition(0, 0, 0, 0.5, 0.5, model, out);
      expect(out[0], closeTo(3, 1e-9));
      expect(out[1], closeTo(4, 1e-9));
      expect(out[2], closeTo(5, 1e-9));
    });

    test('decomposeWorldMatrix round-trips position, scale and rotation', () {
      final m = Mat4.compose(const Vec3(1, -2, 3),
          const Euler(0.3, -0.2, 0.1), const Vec3(2, 2, 2));
      final d = decomposeWorldMatrix(m);

      expect(d.position.x, closeTo(1, 1e-9));
      expect(d.position.y, closeTo(-2, 1e-9));
      expect(d.position.z, closeTo(3, 1e-9));
      expect(d.scale.x, closeTo(2, 1e-9));
      expect(d.euler.x, closeTo(0.3, 1e-6));
      expect(d.euler.y, closeTo(-0.2, 1e-6));
      expect(d.euler.z, closeTo(0.1, 1e-6));
    });
  });

  group('filter', () {
    late DogFaceFilter filter;
    late JeelizFaceFilterHelper helper;
    late PerspectiveCamera camera;
    late Framebuffer fb;
    late SoftwareRenderer renderer;

    setUp(() async {
      filter = DogFaceFilter();
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

    DetectState head({double mouth = 0}) => DetectState(
        detected: 1,
        x: 0,
        y: 0,
        s: 0.35,
        rx: 0,
        ry: 0,
        rz: 0,
        expressions: [mouth]);

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

    test('loads ears, nose and tongue', () {
      final meshes = <Mesh>[];
      helper.faceObject.traverse((o) {
        if (o is Mesh) meshes.add(o);
      });
      expect(meshes.map((m) => m.name).toSet(),
          {'dogEars', 'dogNose', 'dogTongue'});

      final tongue = meshes.firstWhere((m) => m.name == 'dogTongue');
      expect(tongue.geometry.hasMorphTargets, isTrue);
      expect(tongue.geometry.morphPositions.length, 26);
      expect(tongue.morphInfluences.length, 26);
    });

    test('a detected face draws the dog', () {
      draw(head());
      expect(drawnPixels(), greaterThan(1500));
      expect(renderer.stats.fragments, greaterThan(0));
    });

    test('the vignette overlay is built', () {
      expect(filter.foreground, isNotNull);
      expect(filter.foreground!.width, greaterThan(32));
    });

    test('the tongue only comes out past the 0.85 gate', () {
      draw(head(mouth: 0.0));
      expect(filter.tongueProgress, 0);

      // Mid-open must not trigger it — the original latches at >= 0.85.
      for (var i = 0; i < 10; i++) {
        draw(head(mouth: 0.5));
      }
      expect(filter.tongueProgress, 0, reason: 'below the gate');

      for (var i = 0; i < 40; i++) {
        draw(head(mouth: 0.95));
      }
      expect(filter.tongueProgress, greaterThan(0.5));
      expect(filter.isTongueOut, isTrue);

      // And it stays out until the mouth is properly shut (<= 0.1), not merely
      // less open.
      for (var i = 0; i < 5; i++) {
        draw(head(mouth: 0.5));
      }
      expect(filter.tongueProgress, greaterThan(0.5), reason: 'still latched');

      for (var i = 0; i < 60; i++) {
        draw(head(mouth: 0.0));
      }
      expect(filter.tongueProgress, closeTo(0, 1e-9));
      expect(filter.isTongueOut, isFalse);
    });

    test('morph influences always sum to one while animating', () {
      for (var i = 0; i < 30; i++) {
        draw(head(mouth: 0.95));
        final tongue = _findMesh(helper, 'dogTongue')!;
        final sum = tongue.morphInfluences.fold<double>(0, (a, b) => a + b);
        expect(sum, closeTo(1.0, 1e-9),
            reason: 'a two-frame lerp must be a partition of unity');
      }
    });

    test('an undetected face draws nothing', () {
      draw(DetectState.lost);
      expect(helper.isDetected, isFalse);
      expect(drawnPixels(), 0);
    });

    test('renders within a frame budget', () {
      draw(head(mouth: 0.95));
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        draw(head(mouth: 0.95));
      }
      sw.stop();
      final perFrameMs = sw.elapsedMilliseconds / 10;
      expect(perFrameMs, lessThan(400), reason: '${perFrameMs}ms per frame');
    });
  });
}

Mesh? _findMesh(JeelizFaceFilterHelper helper, String name) {
  Mesh? found;
  helper.faceObject.traverse((o) {
    if (o is Mesh && o.name == name) found = o;
  });
  return found;
}

/// Captures the mean view-space Y of the fragments it shades, so a vertex-stage
/// change (like morphing) is measurable.
class _PositionProbe extends Material {
  double _sum = 0;
  int samples = 0;

  @override
  MaterialSide get side => MaterialSide.double;

  double get meanViewY => samples == 0 ? 0 : _sum / samples;

  void reset() {
    _sum = 0;
    samples = 0;
  }

  @override
  bool shade(Fragment f, Float64List out) {
    _sum += f.vy;
    samples++;
    out[0] = out[1] = out[2] = out[3] = 1;
    return true;
  }
}
