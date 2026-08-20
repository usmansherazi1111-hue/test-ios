// Tests for demos/threejs/luffys_hat_part1 and luffys_hat_part2.
//
// The two demos differ only in data, so most of these tests are a diff: what
// part 2 adds, what it re-seats, and what it moves out of the scene graph
// entirely (the tracking pivot). The rest pin part 1's three dead lines as
// deliberate, since each one reads like something a port should "fix".

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

VideoLumaTexture video(int w, int h, List<double> Function(double u, double v) f) {
  final t = VideoLumaTexture(w, h, color: true);
  final rgb = t.rgb!;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = f((x + 0.5) / w, (y + 0.5) / h);
      final i = (y * w + x) * 3;
      rgb[i] = (c[0] * 255).round().clamp(0, 255);
      rgb[i + 1] = (c[1] * 255).round().clamp(0, 255);
      rgb[i + 2] = (c[2] * 255).round().clamp(0, 255);
      t.luma[y * w + x] = ((c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114) * 255)
          .round()
          .clamp(0, 255);
    }
  }
  return t;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LuffysHatFilter, JeelizFaceFilterHelper, PerspectiveCamera)> build(
    LuffysHatPart part, {
    bool frame = false,
    int w = 270,
    int h = 480,
  }) async {
    final f = LuffysHatFilter(
        part: part, showFrame: frame, textureMaxWidth: 128);
    await f.load();
    final helper = JeelizFaceFilterHelper(
      settings: JeelizHelperSettings(
        pivotOffsetYZ:
            f.preferredPivotOffsetYZ ?? const JeelizHelperSettings().pivotOffsetYZ,
      ),
    );
    final camera = helper.createCamera();
    helper.updateCamera(camera,
        canvasWidth: w.toDouble(),
        canvasHeight: h.toDouble(),
        videoWidth: w.toDouble(),
        videoHeight: h.toDouble());
    f.attach(helper);
    return (f, helper, camera);
  }

  const head =
      DetectState(detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);

  int drawn(Framebuffer fb) {
    var n = 0;
    for (var i = 3; i < fb.color.length; i += 4) {
      if (fb.color[i] > 0) n++;
    }
    return n;
  }

  Framebuffer render(
      LuffysHatFilter f, JeelizFaceFilterHelper helper, PerspectiveCamera cam,
      {int w = 270, int h = 480}) {
    helper.update(const [head], cam);
    f.update(head, 1 / 30);
    final fb = Framebuffer(w, h);
    fb.clear();
    SoftwareRenderer().render(helper.scene, cam, fb);
    return fb;
  }

  group('part 1', () {
    test('is one mesh parented straight to the face object', () async {
      final (f, helper, _) = await build(LuffysHatPart.part1);
      expect(helper.faceObject.children.length, 1);
      final hat = helper.faceObject.children.single;
      expect(hat, isA<Mesh>());
      expect(hat.children, isEmpty, reason: 'no group, nothing to drag');
      expect(f.isDraggable, isFalse);
    });

    test('sits at the demo\'s transform, -40 radians and all', () async {
      // `rotation.set(0, -40, 0)` — three's Euler is radians, so this is
      // 3.98 rad (about 228 degrees) once wrapped, not the -40 degrees the
      // author almost certainly meant. Reproduced, because it is where the
      // bow actually ends up on screen.
      expect(LuffysHatFilter.kPart1RotationY, -40.0);

      final (_, helper, _) = await build(LuffysHatPart.part1);
      final hat = helper.faceObject.children.single as Mesh;
      expect(hat.scale.x, 1.2);
      expect(hat.rotation.y, -40.0);
      expect(hat.rotation.x, 0.0);
      expect(hat.rotation.z, 0.0);
      expect(hat.position.y, 0.6);
      expect(hat.position.x, 0.0);
      expect(hat.position.z, 0.0);
    });

    test('the hat material is unlit, so the ambient light is inert', () async {
      // `MeshBasicMaterial` ignores lights entirely. Both demos add an
      // AmbientLight anyway.
      final (_, helper, _) = await build(LuffysHatPart.part1);
      final hat = helper.faceObject.children.single as Mesh;
      final mat = hat.materials.single;
      expect(mat, isA<BasicColorMaterial>());
      expect((mat as BasicColorMaterial).map, isNotNull);
      expect(mat.needsNormals, isFalse);

      var lights = 0;
      void walk(Object3D o) {
        if (o is AmbientLight || o is DirectionalLight || o is PointLight) {
          lights++;
        }
        for (final c in o.children) {
          walk(c);
        }
      }

      walk(helper.scene);
      expect(lights, 0,
          reason: 'the demo adds one; it changes nothing, so it is not ported');
    });

    test('the mesh stays front-faced despite `mesh.side = DoubleSide`',
        () async {
      // `side` is a material property. Assigning it to the Mesh is inert.
      final (_, helper, _) = await build(LuffysHatPart.part1);
      final hat = helper.faceObject.children.single as Mesh;
      expect(hat.materials.single.side, MaterialSide.front);
    });

    test('needs no camera and has no frame', () async {
      final (f, _, _) = await build(LuffysHatPart.part1, frame: true);
      expect(f.needsVideo, isFalse);
      expect(f.needsVideoColor, isFalse);
      expect(f.foreground, isNull, reason: 'part 1 ships no cadre');
    });

    test('leaves the tracking pivot alone', () async {
      final (f, _, _) = await build(LuffysHatPart.part1);
      expect(f.preferredPivotOffsetYZ, isNull);
    });

    test('draws the hat', () async {
      final (f, helper, cam) = await build(LuffysHatPart.part1);
      expect(drawn(render(f, helper, cam)), greaterThan(1000));
    });
  });

  group('part 2', () {
    test('is a group of hat plus face fill', () async {
      final (f, helper, _) = await build(LuffysHatPart.part2);
      final group = helper.faceObject.children.single;
      expect(group, isNot(isA<Mesh>()), reason: 'HATOBJ3D is a plain Object3D');
      expect(group.children.length, 2);
      expect(group.children.map((c) => c.name),
          containsAll(<String>['luffysHat', 'luffysFaceFill']));
      expect(f.isDraggable, isTrue);
    });

    test('re-seats the hat', () async {
      final (_, helper, _) = await build(LuffysHatPart.part2);
      final hat = helper.faceObject.children.single.children
          .firstWhere((c) => c.name == 'luffysHat') as Mesh;
      expect(hat.scale.x, closeTo(1.1 * 1.1, 1e-12));
      expect(hat.rotation.x, -0.1);
      expect(hat.rotation.y, 0.0, reason: 'no -40 here');
      expect(hat.position.y, 0.7);
      expect(hat.position.z, -0.3);
    });

    test('places the face fill', () async {
      final (_, helper, _) = await build(LuffysHatPart.part2);
      final face = helper.faceObject.children.single.children
          .firstWhere((c) => c.name == 'luffysFaceFill') as Mesh;
      expect(face.scale.x, closeTo(1.12 * 1.1, 1e-12));
      expect(face.position.y, 0.5);
      expect(face.position.z, -0.75);
      // The mesh ships positions only; normals are computed on load.
      expect(face.geometry.hasSuppliedNormals, isFalse);
    });

    test('moves the tracking pivot, which the scene graph cannot express',
        () async {
      // `set_pivotOffsetYZ([0.2, 0.6 - 0.1])`.
      expect(LuffysHatFilter.kPart2PivotOffsetYZ, [0.2, 0.5]);
      final f = LuffysHatFilter(part: LuffysHatPart.part2);
      expect(f.preferredPivotOffsetYZ, [0.2, 0.5]);
      expect(const JeelizHelperSettings().pivotOffsetYZ, [0.2, 0.6],
          reason: 'the default it overrides');
    });

    test('the pivot actually changes where the hat lands', () async {
      // Not a no-op knob: with the head pitched, the two pivots put the hat in
      // measurably different places.
      const pitched =
          DetectState(detected: 1, x: 0, y: 0, s: 0.4, rx: 0.5, ry: 0, rz: 0);

      Vec3 hatWorldWith(List<double> pivot) {
        final helper = JeelizFaceFilterHelper(
            settings: JeelizHelperSettings(pivotOffsetYZ: pivot));
        final cam = helper.createCamera();
        helper.updateCamera(cam,
            canvasWidth: 270,
            canvasHeight: 480,
            videoWidth: 270,
            videoHeight: 480);
        final probe = Object3D(name: 'probe')
          ..position = LuffysHatFilter.kPart2HatPosition;
        helper.faceObject.add(probe);
        helper.update(const [pitched], cam);
        helper.scene.updateMatrixWorld(null);
        final m = probe.matrixWorld;
        return Vec3(m.m[12], m.m[13], m.m[14]);
      }

      final a = hatWorldWith(const [0.2, 0.6]);
      final b = hatWorldWith(LuffysHatFilter.kPart2PivotOffsetYZ);
      final d = (a.x - b.x).abs() + (a.y - b.y).abs() + (a.z - b.z).abs();
      expect(d, greaterThan(0.01), reason: '$a vs $b');
    });

    test('reuses rupy_helmet\'s face shader with two constants widened',
        () async {
      // Same ShaderMaterial, `smoothstep(0., 0.85, ...)` and
      // `smoothstep(-0.15, 0.15, ...)` instead of 0.55 and 0.05.
      final (f, _, _) = await build(LuffysHatPart.part2);
      final mat = f.faceMaterial!;
      expect(mat.borderHigh, 0.85);
      expect(mat.darkenHigh, 0.15);
      expect(HelmetFaceMaterial.kRupyBorderHigh, 0.55);
      expect(HelmetFaceMaterial.kRupyDarkenHigh, 0.05);
    });

    test('the widened border keeps more of the profile opaque', () async {
      // The point of 0.85 over 0.55: at a given angle away from the camera,
      // Luffy's fill is *less* opaque, so the edge feathers over a wider band.
      final rupy = HelmetFaceMaterial(video: video(8, 8, (u, v) => const [0.5, 0.5, 0.5]));
      final luffy = HelmetFaceMaterial(
        video: video(8, 8, (u, v) => const [0.5, 0.5, 0.5]),
        borderHigh: HelmetFaceMaterial.kLuffyBorderHigh,
        darkenHigh: HelmetFaceMaterial.kLuffyDarkenHigh,
      );

      // The material normalises, so tilting means giving the normal real x —
      // `nz` alone with zero x and y is still a unit normal facing the camera.
      Float64List shadeAt(HelmetFaceMaterial m, double nz) {
        final fr = Fragment()
          ..nx = math.sqrt(1 - nz * nz)
          ..ny = 0
          ..nz = nz
          ..oy = 0.5
          ..vpU = 0.5
          ..vpV = 0.5;
        final out = Float64List(4);
        m.shade(fr, out);
        return out;
      }

      // Half turned away.
      expect(shadeAt(luffy, 0.6)[3], lessThan(shadeAt(rupy, 0.6)[3]));
      // Facing the camera, both are fully opaque.
      expect(shadeAt(luffy, 1.0)[3], closeTo(1.0, 1e-9));
      expect(shadeAt(rupy, 1.0)[3], closeTo(1.0, 1e-9));
    });

    test('the widened darkening spreads over twice the height', () async {
      final luffy = HelmetFaceMaterial(
        video: video(8, 8, (u, v) => const [1.0, 1.0, 1.0]),
        borderHigh: HelmetFaceMaterial.kLuffyBorderHigh,
        darkenHigh: HelmetFaceMaterial.kLuffyDarkenHigh,
      );
      final rupy =
          HelmetFaceMaterial(video: video(8, 8, (u, v) => const [1.0, 1.0, 1.0]));

      double greenAt(HelmetFaceMaterial m, double oy) {
        final fr = Fragment()
          ..nx = 0
          ..ny = 0
          ..nz = 1
          ..oy = oy
          ..vpU = 0.5
          ..vpV = 0.5;
        final out = Float64List(4);
        m.shade(fr, out);
        return out[1];
      }

      // At y = 0.05 rupy has already finished darkening to black; luffy has
      // not, so it still shows some video.
      expect(greenAt(rupy, 0.1), closeTo(0.0, 1e-9));
      expect(greenAt(luffy, 0.1), greaterThan(0.0));
      // Both are fully dark well above the band.
      expect(greenAt(luffy, 0.5), closeTo(0.0, 1e-9));
    });

    test('needs colour camera, for the face fill', () async {
      final (f, _, _) = await build(LuffysHatPart.part2);
      expect(f.needsVideo, isTrue);
      expect(f.needsVideoColor, isTrue);
    });

    test('carries the cadre as a full-screen foreground', () async {
      final (f, _, _) = await build(LuffysHatPart.part2, frame: true);
      expect(f.foreground, isNotNull);
      expect(f.foregroundLayout, ForegroundLayout.fill,
          reason: 'the demo stretches it with a screen-space quad');
    });

    test('the frame can be turned off', () async {
      final (f, _, _) = await build(LuffysHatPart.part2);
      expect(f.foreground, isNull);
    });

    test('dragging moves hat and face fill together', () async {
      final (f, helper, cam) = await build(LuffysHatPart.part2);
      final group = helper.faceObject.children.single;
      f.offset = const Vec3(0.2, -0.1, 0);
      render(f, helper, cam);
      expect(group.position.x, 0.2);
      expect(group.position.y, -0.1);
      // The children keep their own offsets inside the group.
      final hat = group.children.firstWhere((c) => c.name == 'luffysHat');
      expect(hat.position.y, 0.7);
    });

    test('draws both meshes', () async {
      final (f, helper, cam) = await build(LuffysHatPart.part2);
      f.setVideo(video(64, 64, (u, v) => const [0.8, 0.6, 0.4]));
      final withBoth = drawn(render(f, helper, cam));

      final (f1, h1, c1) = await build(LuffysHatPart.part1);
      final hatOnly = drawn(render(f1, h1, c1));

      expect(withBoth, greaterThan(hatOnly),
          reason: 'the face fill adds coverage the hat alone does not');
    });

    test('an undetected face draws nothing', () async {
      final (f, helper, cam) = await build(LuffysHatPart.part2);
      f.setVideo(video(64, 64, (u, v) => const [0.8, 0.6, 0.4]));
      helper.update(const [DetectState.lost], cam);
      final fb = Framebuffer(160, 240);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });
  });

  group('shared', () {
    test('both parts load the same hat geometry', () async {
      final (a, ha, _) = await build(LuffysHatPart.part1);
      final (b, hb, _) = await build(LuffysHatPart.part2);

      Mesh hatOf(JeelizFaceFilterHelper h) {
        final root = h.faceObject.children.single;
        return root is Mesh
            ? root
            : root.children.firstWhere((c) => c.name == 'luffysHat') as Mesh;
      }

      // 4179 vertices, 8064 triangles, with UVs and normals in the file.
      for (final m in [hatOf(ha), hatOf(hb)]) {
        expect(m.geometry.positions.length, 4179 * 3);
        expect(m.geometry.indices.length, 24192);
        expect(m.geometry.uvs, isNotNull);
        expect(m.geometry.hasSuppliedNormals, isTrue);
      }
      expect(a.part, LuffysHatPart.part1);
      expect(b.part, LuffysHatPart.part2);
    });

    test('the two parts use different hat textures', () async {
      // Part 1: models/Texture.jpg. Part 2: models/luffys_hat/Texture2.jpg —
      // a different file, and a third (models/Texture2.jpg) neither loads.
      final (_, ha, _) = await build(LuffysHatPart.part1);
      final (_, hb, _) = await build(LuffysHatPart.part2);

      Texture2D texOf(JeelizFaceFilterHelper h) {
        final root = h.faceObject.children.single;
        final mesh = root is Mesh
            ? root
            : root.children.firstWhere((c) => c.name == 'luffysHat') as Mesh;
        return (mesh.materials.single as BasicColorMaterial).map!;
      }

      expect(texOf(ha).rgba, isNot(texOf(hb).rgba));
    });

    test('detach clears the scene either way', () async {
      for (final part in LuffysHatPart.values) {
        final (f, helper, _) = await build(part);
        expect(helper.faceObject.children, isNotEmpty);
        f.detach(helper);
        expect(helper.faceObject.children, isEmpty);
        expect(f.faceMaterial, isNull);
      }
    });

    test('renders within a frame budget', () async {
      for (final part in LuffysHatPart.values) {
        final (f, helper, cam) = await build(part);
        f.setVideo(video(192, 192, (u, v) => [u, v, 0.5]));
        final fb = Framebuffer(270, 480);
        final renderer = SoftwareRenderer();

        for (var i = 0; i < 2; i++) {
          helper.update(const [head], cam);
          f.update(head, 1 / 30);
          fb.clear();
          renderer.render(helper.scene, cam, fb);
        }

        final sw = Stopwatch()..start();
        const frames = 5;
        for (var i = 0; i < frames; i++) {
          helper.update(const [head], cam);
          f.update(head, 1 / 30);
          fb.clear();
          renderer.render(helper.scene, cam, fb);
        }
        sw.stop();
        final ms = sw.elapsedMicroseconds / 1000 / frames;
        // ignore: avoid_print
        print('luffysHat ${part.name}: ${ms.toStringAsFixed(1)} ms/frame '
            'at 270x480 (${renderer.stats})');
        expect(ms, lessThan(600), reason: '$part ${ms.toStringAsFixed(1)} ms');
      }
    });
  });

  group('BasicColorMaterial with a map', () {
    test('multiplies the texture into the colour', () {
      final px = Uint8List.fromList(<int>[
        255, 0, 0, 255, //
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 255, 255,
      ]);
      final tex = Texture2D(2, 2, px);
      final m = BasicColorMaterial(color: const Vec3(0.5, 0.5, 0.5), map: tex);

      final f = Fragment()
        ..u = 0.25
        ..v = 0.75; // v counts from the bottom in Texture2D.sample
      final out = Float64List(4);
      expect(m.shade(f, out), isTrue);
      expect(out[0], closeTo(0.5, 0.02));
      expect(out[1], closeTo(0.0, 0.02));
      expect(out[2], closeTo(0.0, 0.02));
      expect(out[3], 1.0);
    });

    test('without a map it is still the flat-colour material', () {
      final m = BasicColorMaterial(color: const Vec3(0.2, 0.4, 0.6));
      final out = Float64List(4);
      expect(m.shade(Fragment(), out), isTrue);
      expect(out[0], 0.2);
      expect(out[1], 0.4);
      expect(out[2], 0.6);
    });
  });
}
