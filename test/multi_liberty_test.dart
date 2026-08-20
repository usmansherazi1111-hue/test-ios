// Renders the real multiLiberty assets.
//
// This is the first multi-face port, so the thing most worth pinning is that a
// second face genuinely gets its own posed statue rather than a copy of the
// first one's — a bug that would look completely fine with one person in frame.
//
// Also new: `sortGeometryFaces` (a reorder that changes nothing visible unless
// you look at blend order) and the `srcColorAdd` blend, which is `dst += src²`
// and easy to confuse with plain additive.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sortGeometryFaces', () {
    /// Four triangles at known, distinct depths.
    BufferGeometry depthStack() {
      final pos = <double>[];
      final idx = <int>[];
      for (var i = 0; i < 4; i++) {
        final z = i.toDouble(); // 0, 1, 2, 3
        final base = i * 3;
        pos.addAll([0, 0, z, 1, 0, z, 0, 1, z]);
        idx.addAll([base, base + 1, base + 2]);
      }
      return BufferGeometry(
        positions: Float32List.fromList(pos),
        indices: Uint32List.fromList(idx),
      );
    }

    List<double> centroidZs(BufferGeometry g) {
      final out = <double>[];
      for (var i = 0; i < g.triangleCount; i++) {
        final a = g.indices[3 * i] * 3 + 2;
        final b = g.indices[3 * i + 1] * 3 + 2;
        final c = g.indices[3 * i + 2] * 3 + 2;
        out.add((g.positions[a] + g.positions[b] + g.positions[c]) / 3);
      }
      return out;
    }

    test('sorts ascending by centroid depth', () {
      final g = depthStack();
      sortGeometryFaces(g, SortAxis.z);
      expect(centroidZs(g), [0.0, 1.0, 2.0, 3.0]);
    });

    test('inverted sorts descending — what multiLiberty asks for', () {
      final g = depthStack();
      sortGeometryFaces(g, SortAxis.z, inverted: true);
      expect(centroidZs(g), [3.0, 2.0, 1.0, 0.0]);
    });

    test('keeps each triangle intact rather than shuffling vertices', () {
      // A reorder that split triangles across the buffer would still "sort"
      // but would render garbage.
      // Compared as joined strings: Dart's Set and List both use *identity*
      // equality, so `contains` on collections would never match here.
      List<String> triangleKeys(BufferGeometry g) => [
            for (var i = 0; i < g.triangleCount; i++)
              ([g.indices[3 * i], g.indices[3 * i + 1], g.indices[3 * i + 2]]
                    ..sort())
                  .join(',')
          ];

      final g = depthStack();
      final before = triangleKeys(g);
      sortGeometryFaces(g, SortAxis.z, inverted: true);
      final after = triangleKeys(g);

      expect(after.toSet(), before.toSet(),
          reason: 'the same triangles, reordered — none split or duplicated');
      expect(after.length, before.length);
      expect(after, isNot(before), reason: 'and the order really did change');
    });

    test('a single-triangle geometry is left alone', () {
      final g = BufferGeometry(
        positions: Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
        indices: Uint32List.fromList([0, 1, 2]),
      );
      sortGeometryFaces(g, SortAxis.z);
      expect(g.indices, [0, 1, 2]);
    });
  });

  group('srcColorAdd blending', () {
    test('adds the square of the source, not the source', () {
      // A half-grey quad over an empty framebuffer: plain additive would land
      // at 0.5, this lands at 0.25.
      final camera = PerspectiveCamera(fov: 60, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(16, 16)..clear();

      final scene = Scene()
        ..add(Mesh(
          _quad(),
          BasicColorMaterial(
            color: const Vec3(0.5, 0.5, 0.5),
            transparent: true,
            side: MaterialSide.double,
            blend: BlendMode.srcColorAdd,
          ),
        ));
      SoftwareRenderer().render(scene, camera, fb);

      const centre = (8 * 16 + 8) * 4;
      expect(fb.color[centre], closeTo(0.25 * 255, 2),
          reason: 'dst += src * src');

      // The same colour with plain additive lands at 0.5 — proof the two
      // modes are not accidentally the same code path.
      final fb2 = Framebuffer(16, 16)..clear();
      final scene2 = Scene()
        ..add(Mesh(
          _quad(),
          BasicColorMaterial(
            color: const Vec3(0.5, 0.5, 0.5),
            transparent: true,
            side: MaterialSide.double,
            blend: BlendMode.additive,
          ),
        ));
      SoftwareRenderer().render(scene2, camera, fb2);
      expect(fb2.color[centre], closeTo(0.5 * 255, 2));
    });
  });

  group('Lambert alphaMap', () {
    test('reads the green channel, as three does', () {
      final out = Float64List(4);
      final f = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..lights = LightingContext(const Vec3(1, 1, 1), const []);

      // Green at half, red and blue at full: only green should matter.
      final tex = Texture2D.solid(255, 128, 255);
      LambertMaterial(alphaMap: tex, transparent: true).shade(f, out);
      expect(out[3], closeTo(128 / 255, 0.01));

      // Opaque green => fully opaque.
      LambertMaterial(alphaMap: Texture2D.solid(0, 255, 0), transparent: true)
          .shade(f, out);
      expect(out[3], closeTo(1.0, 0.01));
    });
  });

  group('multi-face', () {
    test('a controller builds one adapter and face object per slot', () {
      final c = JeelizFilterController(
          filter: MultiLibertyFilter(), maxFaces: 4);
      expect(c.maxFaces, 4);
      expect(c.adapters.length, 4);
      expect(c.helper.faceObjects.length, 4);
      expect(c.lastStates.length, 4);
      // The single-face conveniences still resolve to slot 0.
      expect(identical(c.adapter, c.adapters.first), isTrue);
      c.dispose();
    });

    test('maxFaces below 1 is clamped rather than crashing', () {
      final c = JeelizFilterController(filter: MultiLibertyFilter(), maxFaces: 0);
      expect(c.maxFaces, 1);
      c.dispose();
    });

    test('each face slot poses independently', () async {
      final filter = MultiLibertyFilter();
      await filter.load();
      final helper = JeelizFaceFilterHelper(maxFacesDetected: 3);
      final camera = helper.createCamera();
      filter.attach(helper);
      helper.updateCamera(camera,
          canvasWidth: 270,
          canvasHeight: 480,
          videoWidth: 720,
          videoHeight: 1280);

      // Two faces at different places, third slot empty.
      const a = DetectState(
          detected: 1, x: -0.5, y: 0.1, s: 0.3, rx: 0, ry: 0, rz: 0);
      const b = DetectState(
          detected: 1, x: 0.5, y: -0.1, s: 0.4, rx: 0, ry: 0.3, rz: 0);
      helper.update([a, b, DetectState.lost], camera);
      helper.scene.updateMatrixWorld();

      final objs = helper.faceObjects;
      expect(objs[0].visible, isTrue);
      expect(objs[1].visible, isTrue);
      expect(objs[2].visible, isFalse, reason: 'no third face');

      // The two visible faces must have landed in genuinely different places.
      final p0 = objs[0].position, p1 = objs[1].position;
      expect((p0.x - p1.x).abs(), greaterThan(0.1));
      expect(objs[0].rotation.y, isNot(closeTo(objs[1].rotation.y, 1e-6)));
    });

    test('every face slot gets its own statue sharing one geometry', () async {
      final filter = MultiLibertyFilter();
      await filter.load();
      final helper = JeelizFaceFilterHelper(maxFacesDetected: 4);
      filter.attach(helper);

      final statues = <Mesh>[];
      for (final f in helper.faceObjects) {
        f.traverse((o) {
          if (o is Mesh && o.name == 'liberty') statues.add(o);
        });
      }
      expect(statues.length, 4, reason: 'one per face slot');

      // three's `.clone()` shares geometry and material; 15,932 triangles are
      // not duplicated four times.
      for (final s in statues.skip(1)) {
        expect(identical(s.geometry, statues.first.geometry), isTrue);
        expect(identical(s.material, statues.first.material), isTrue);
      }
    });
  });

  group('filter', () {
    late MultiLibertyFilter filter;
    late JeelizFaceFilterHelper helper;
    late PerspectiveCamera camera;
    late Framebuffer fb;
    late SoftwareRenderer renderer;

    setUp(() async {
      filter = MultiLibertyFilter();
      await filter.load();
      helper = JeelizFaceFilterHelper(maxFacesDetected: 2);
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

    int drawnPixels() {
      var n = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) n++;
      }
      return n;
    }

    void draw(List<DetectState> states) {
      helper.update(states, camera);
      filter.update(states.first, 1 / 30);
      fb.clear();
      renderer.render(helper.scene, camera, fb);
    }

    test('geometry loads with the expected topology', () {
      final meshes = <Mesh>[];
      helper.faceObjects.first.traverse((o) {
        if (o is Mesh) meshes.add(o);
      });
      final byName = {for (final m in meshes) m.name: m};
      expect(byName['liberty']!.geometry.triangleCount, 15932);
      expect(byName['libertyFaceMask']!.geometry.triangleCount, 971);
      // The mask ships positions only, so normals were computed on load.
      expect(byName['libertyFaceMask']!.geometry.hasSuppliedNormals, isFalse);
    });

    test('one detected face draws the statue', () {
      draw(const [
        DetectState(detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0),
        DetectState.lost,
      ]);
      expect(drawnPixels(), greaterThan(1000));
      expect(renderer.stats.fragments, greaterThan(0));
    });

    test('two detected faces draw more than one', () {
      draw(const [
        DetectState(detected: 1, x: -0.4, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
        DetectState.lost,
      ]);
      final one = drawnPixels();

      draw(const [
        DetectState(detected: 1, x: -0.4, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
        DetectState(detected: 1, x: 0.4, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
      ]);
      final two = drawnPixels();

      expect(two, greaterThan(one * 1.5),
          reason: 'a second face is a second statue, not a redraw');
    });

    test('no detected faces draws nothing', () {
      draw(const [DetectState.lost, DetectState.lost]);
      expect(helper.isDetected, isFalse);
      expect(drawnPixels(), 0);
    });

    test('renders within a frame budget with two faces', () {
      const states = [
        DetectState(detected: 1, x: -0.4, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
        DetectState(detected: 1, x: 0.4, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
      ];
      draw(states);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        draw(states);
      }
      sw.stop();
      final perFrameMs = sw.elapsedMilliseconds / 10;
      expect(perFrameMs, lessThan(500), reason: '${perFrameMs}ms per frame');
    });
  });
}

BufferGeometry _quad() => BufferGeometry(
      positions: Float32List.fromList(
          [-1, -1, -2, 1, -1, -2, 1, 1, -2, -1, 1, -2]),
      indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
      normals: Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]),
    );
