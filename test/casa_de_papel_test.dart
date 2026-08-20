// Renders the real casa_de_papel assets.
//
// The new machinery here is the tangent frame for normal mapping, which has no
// visual tell when it is subtly wrong — a mirrored or transposed basis still
// produces plausible-looking bumps, just lit from the wrong side. So it gets
// tested against a case with a known answer rather than by eyeballing a render.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('normal mapping', () {
    test('a flat normal map leaves the surface normal alone', () {
      // The neutral texel (128, 128, 255) decodes to (0, 0, 1) — straight up
      // in tangent space — and must reproduce the geometric normal exactly.
      final f = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..tx = 1
        ..ty = 0
        ..tz = 0
        ..bx = 0
        ..by = 1
        ..bz = 0;

      final n = f.applyNormalMap(0, 0, 1);
      expect(n.x, closeTo(0, 1e-12));
      expect(n.y, closeTo(0, 1e-12));
      expect(n.z, closeTo(1, 1e-12));
    });

    test('tangent-space X tilts along the tangent, not the bitangent', () {
      final f = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..tx = 1
        ..ty = 0
        ..tz = 0
        ..bx = 0
        ..by = 1
        ..bz = 0;

      final n = f.applyNormalMap(1, 0, 1);
      expect(n.x, greaterThan(0.5), reason: 'tilts along +tangent');
      expect(n.y, closeTo(0, 1e-12), reason: 'not along the bitangent');
    });

    test('the frame the rasteriser builds matches the UV layout', () {
      // A triangle in the view-space XY plane whose U runs along +X and V
      // along +Y. The recovered tangent must therefore be +X, bitangent +Y.
      final geom = BufferGeometry(
        positions: Float32List.fromList([
          0, 0, -2, //
          1, 0, -2, //
          0, 1, -2,
        ]),
        indices: Uint32List.fromList([0, 1, 2]),
        normals: Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
        uvs: Float32List.fromList([0, 0, 1, 0, 0, 1]),
      );

      final probe = _TangentProbe();
      final scene = Scene()..add(Mesh(geom, probe));
      final camera = PerspectiveCamera(fov: 60, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(64, 64)..clear();
      SoftwareRenderer().render(scene, camera, fb);

      expect(probe.samples, greaterThan(0), reason: 'triangle must rasterise');
      expect(probe.tx, closeTo(1, 1e-6));
      expect(probe.ty, closeTo(0, 1e-6));
      expect(probe.bx, closeTo(0, 1e-6));
      expect(probe.by, closeTo(1, 1e-6));
    });
  });

  group('phong', () {
    test('an emissive map alone contributes nothing', () {
      // three multiplies the emissive map into `emissive`, which defaults to
      // black. casa_de_papel ships CasaDePapel_REFLECT.png and never raises
      // emissive, so it is inert — reproducing that is the point.
      final white = Texture2D.solid(255, 255, 255);
      final mat = PhongMaterial(emissiveMap: white);
      final out = Float64List(4);

      final f = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..vz = -1
        ..lights = LightingContext(Vec3.zero, const []);

      expect(mat.shade(f, out), isTrue);
      expect(out[0], closeTo(0, 1e-12), reason: 'black emissive stays black');

      // Raise emissive and the map starts mattering.
      mat.emissive = const Vec3(1, 1, 1);
      mat.shade(f, out);
      expect(out[0], closeTo(1, 1e-9));
    });

    test('specular adds a highlight on top of diffuse', () {
      final lit = LightingContext(
        Vec3.zero,
        [(direction: const Vec3(0, 0, 1), color: const Vec3(1, 1, 1))],
      );
      final out = Float64List(4);

      // Normal, light and eye all aligned: the half vector is the normal, so
      // the highlight is at its maximum.
      final headOn = Fragment()
        ..nx = 0
        ..ny = 0
        ..nz = 1
        ..vz = -1
        ..lights = lit;

      PhongMaterial(specular: Vec3.zero).shade(headOn, out);
      final diffuseOnly = out[0];

      PhongMaterial(specular: const Vec3(1, 1, 1)).shade(headOn, out);
      expect(out[0], greaterThan(diffuseOnly), reason: 'specular adds energy');
    });
  });

  group('filter', () {
    late CasaDePapelFilter filter;
    late JeelizFaceFilterHelper helper;
    late PerspectiveCamera camera;
    late Framebuffer fb;
    late SoftwareRenderer renderer;

    setUp(() async {
      filter = CasaDePapelFilter();
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

    /// Advances the simulation without rendering — the bills start at y = 3
    /// and fall 0.625 units/second, so they take a few seconds to enter the
    /// frustum and rendering every one of those frames would dominate the
    /// suite's runtime.
    void advance(double seconds, {double dt = 1 / 30}) {
      for (var t = 0.0; t < seconds; t += dt) {
        filter.update(head(), dt);
      }
    }

    int drawnPixels() {
      var n = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) n++;
      }
      return n;
    }

    test('a detected face draws the mask', () {
      draw(head());
      expect(drawnPixels(), greaterThan(2000));
      expect(renderer.stats.fragments, greaterThan(0));
    });

    test('the frame overlay loads as an image', () {
      expect(filter.foreground, isNotNull);
      expect(filter.foreground!.width, greaterThan(64));
    });

    test('bills stay hidden until the heist starts, then fall', () {
      draw(head());
      final maskOnly = drawnPixels();

      filter.startHeist();
      // Release is staggered 230ms apart, and a bill needs ~4s of falling
      // before it drops into view.
      advance(5);
      draw(head());
      expect(drawnPixels(), greaterThan(maskOnly),
          reason: 'falling bills add coverage');

      filter.reset();
      draw(head());
      expect(drawnPixels(), closeTo(maskOnly.toDouble(), maskOnly * 0.05));
    });

    test('bills keep falling with no face detected', () {
      // They live on the scene, not the face object, so losing tracking must
      // not stop them.
      filter.startHeist();
      advance(5);
      draw(DetectState.lost);
      expect(helper.isDetected, isFalse);
      expect(drawnPixels(), greaterThan(0),
          reason: 'world-space content survives losing the face');
    });

    test('bill motion is frame-rate independent', () {
      // The original animates on a 16ms setInterval, so its constants are per
      // tick, not per second. A fixed timestep is what keeps 60fps and 30fps
      // looking the same instead of the money falling twice as fast on a
      // faster phone.
      double runAt(double dt, int frames) {
        filter.reset();
        filter.startHeist();
        for (var i = 0; i < frames; i++) {
          filter.update(head(), dt);
        }
        return filter.bills.first.position.y;
      }

      final at60 = runAt(1 / 60, 120); // 2 seconds
      final at30 = runAt(1 / 30, 60); // also 2 seconds
      expect(at60, closeTo(at30, 0.05));
    });
  });
}

/// Captures the tangent frame the rasteriser hands a fragment.
class _TangentProbe extends Material {
  double tx = 0, ty = 0, bx = 0, by = 0;
  int samples = 0;

  @override
  bool get needsTangents => true;

  @override
  MaterialSide get side => MaterialSide.double;

  @override
  bool shade(Fragment f, Float64List out) {
    tx = f.tx;
    ty = f.ty;
    bx = f.bx;
    by = f.by;
    samples++;
    out[0] = out[1] = out[2] = out[3] = 1;
    return true;
  }
}
