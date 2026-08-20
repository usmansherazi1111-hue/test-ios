// Renders the real rupy_helmet assets.
//
// The parts with no visual tell here: NV21's chroma layout (V before U, half
// resolution — swap them and skin goes green), the face fill's two independent
// falloffs, and the render order, since the face fill is *transparent* yet
// carries `renderOrder = -10000` and must still come after the opaque helmet.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NV21 colour', () {
    /// Builds a full NV21 buffer of one flat YUV colour.
    Uint8List nv21(int w, int h, int y, int u, int v) {
      final buf = Uint8List(w * h + (w * h) ~/ 2);
      buf.fillRange(0, w * h, y);
      for (var i = w * h; i + 1 < buf.length; i += 2) {
        buf[i] = v; // NV21 is V first
        buf[i + 1] = u;
      }
      return buf;
    }

    test('neutral chroma decodes to grey, and luma still works', () {
      final sampler = VideoLumaSampler(maxDimension: 16, color: true);
      final tex = sampler.fromLumaPlane(nv21(32, 32, 200, 128, 128), 32, 32,
          rowStride: 32);

      expect(tex.hasColor, isTrue);
      final out = Float64List(3);
      tex.sampleRgb(0.5, 0.5, out);
      expect(out[0], closeTo(200 / 255, 0.02));
      expect(out[1], closeTo(200 / 255, 0.02));
      expect(out[2], closeTo(200 / 255, 0.02));
      expect(tex.sample(0.5, 0.5), closeTo(200 / 255, 0.02));
    });

    test('V drives red and U drives blue', () {
      final sampler = VideoLumaSampler(maxDimension: 16, color: true);
      final out = Float64List(3);

      // High V => red. If V and U were swapped this would come out blue.
      sampler.fromLumaPlane(nv21(32, 32, 128, 128, 240), 32, 32, rowStride: 32)
          .sampleRgb(0.5, 0.5, out);
      expect(out[0], greaterThan(out[2]), reason: 'high V is red, not blue');

      // High U => blue.
      sampler.fromLumaPlane(nv21(32, 32, 128, 240, 128), 32, 32, rowStride: 32)
          .sampleRgb(0.5, 0.5, out);
      expect(out[2], greaterThan(out[0]), reason: 'high U is blue, not red');
    });

    test('luma-only mode allocates no colour and reads back as grey', () {
      final sampler = VideoLumaSampler(maxDimension: 16);
      final tex =
          sampler.fromLumaPlane(nv21(32, 32, 90, 240, 20), 32, 32, rowStride: 32);

      expect(tex.hasColor, isFalse);
      final out = Float64List(3);
      tex.sampleRgb(0.5, 0.5, out);
      // Falls back to grey rather than black, so a colour-reading filter still
      // shows something if it forgot to ask for colour.
      expect(out[0], closeTo(out[1], 1e-12));
      expect(out[1], closeTo(out[2], 1e-12));
      expect(out[0], closeTo(90 / 255, 0.02));
    });
  });

  group('face fill shader', () {
    VideoLumaTexture flatVideo(int y, int u, int v) {
      final sampler = VideoLumaSampler(maxDimension: 16, color: true);
      final buf = Uint8List(32 * 32 + (32 * 32) ~/ 2);
      buf.fillRange(0, 32 * 32, y);
      for (var i = 32 * 32; i + 1 < buf.length; i += 2) {
        buf[i] = v;
        buf[i + 1] = u;
      }
      return sampler.fromLumaPlane(buf, 32, 32, rowStride: 32);
    }

    Fragment frag({
      double nz = 1,
      double oy = -1,
      double oz = 0,
    }) =>
        Fragment()
          ..nx = 0
          ..ny = 0
          ..nz = nz
          ..vz = -1
          ..oy = oy
          ..oz = oz
          ..vpU = 0.5
          ..vpV = 0.5;

    test('alpha falls to zero at the silhouette', () {
      final mat = HelmetFaceMaterial(video: flatVideo(200, 128, 128));
      final out = Float64List(4);

      // Facing the camera: fully opaque.
      expect(mat.shade(frag(nz: 1), out), isTrue);
      expect(out[3], closeTo(1, 1e-9));

      // Edge-on: discarded, so the mesh's own outline never shows.
      expect(mat.shade(frag(nz: 0), out), isFalse);
    });

    test('the fill darkens towards the top of the head', () {
      final mat = HelmetFaceMaterial(video: flatVideo(220, 128, 128));
      final out = Float64List(4);

      // smoothstep(-0.15, 0.05, vY): low on the head -> bright video.
      mat.shade(frag(oy: -1.0), out);
      final low = out[0];

      // High on the head -> fully darkened.
      mat.shade(frag(oy: 0.5), out);
      final high = out[0];

      expect(low, greaterThan(0.5), reason: 'chin shows the video');
      expect(high, closeTo(0, 1e-9), reason: 'forehead goes black');
    });

    test('mirroring flips only the horizontal lookup', () {
      // A horizontal ramp, so a flipped U is measurable.
      final sampler = VideoLumaSampler(maxDimension: 32, color: true);
      const w = 32, h = 32;
      final buf = Uint8List(w * h + (w * h) ~/ 2);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          buf[y * w + x] = 255 * x ~/ (w - 1);
        }
      }
      buf.fillRange(w * h, buf.length, 128);
      final tex = sampler.fromLumaPlane(buf, w, h, rowStride: w);

      final out = Float64List(4);
      final plain = HelmetFaceMaterial(video: tex)
        ..shade(frag()..vpU = 0.2, out);
      final a = out[0];
      final mirrored = HelmetFaceMaterial(video: tex, mirrorVideo: true)
        ..shade(frag()..vpU = 0.2, out);
      final b = out[0];

      expect(plain, isNotNull);
      expect(mirrored, isNotNull);
      expect(b, greaterThan(a), reason: 'u -> 1-u samples the bright end');
    });
  });

  group('filter', () {
    late RupyHelmetFilter filter;
    late JeelizFaceFilterHelper helper;
    late PerspectiveCamera camera;
    late Framebuffer fb;
    late SoftwareRenderer renderer;

    setUp(() async {
      filter = RupyHelmetFilter(mirrorVideo: false);
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

    DetectState head({double ry = 0}) =>
        DetectState(detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: ry, rz: 0);

    VideoLumaTexture rampVideo() {
      final sampler = VideoLumaSampler(maxDimension: 64, color: true);
      const w = 72, h = 128;
      final buf = Uint8List(w * h + (w * h) ~/ 2);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          buf[y * w + x] = 255 * x ~/ (w - 1);
        }
      }
      buf.fillRange(w * h, buf.length, 128);
      return sampler.fromLumaPlane(buf, w, h, rowStride: w);
    }

    void draw(DetectState s) {
      filter.setVideo(rampVideo());
      helper.update([s], camera);
      filter.update(s, 1 / 30);
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

    test('loads three meshes with the expected topology', () {
      // traverse, not traverseVisible: the face object stays invisible until
      // a face is detected.
      final meshes = <Mesh>[];
      helper.faceObject.traverse((o) {
        if (o is Mesh) meshes.add(o);
      });
      expect(meshes.length, 3);

      final byName = {for (final m in meshes) m.name: m};
      expect(byName['helmet']!.geometry.triangleCount, 9972);
      expect(byName['visor']!.geometry.triangleCount, 3996);
      expect(byName['faceFill']!.geometry.triangleCount, 956);

      // The face fill ships positions only; normals must have been computed.
      final faceGeom = byName['faceFill']!.geometry;
      expect(faceGeom.hasSuppliedNormals, isFalse);
      var nonZero = 0;
      final n = faceGeom.normals;
      for (var i = 0; i < n.length; i += 3) {
        if (n[i] != 0 || n[i + 1] != 0 || n[i + 2] != 0) nonZero++;
      }
      expect(nonZero, faceGeom.vertexCount);
    });

    test('a detected face draws the helmet', () {
      draw(head());
      expect(drawnPixels(), greaterThan(3000));
      expect(renderer.stats.fragments, greaterThan(0));
    });

    test('the frame overlay loads as an image', () {
      expect(filter.foreground, isNotNull);
      expect(filter.foreground!.width, greaterThan(64));
    });

    test('an undetected face draws nothing', () {
      draw(DetectState.lost);
      expect(helper.isDetected, isFalse);
      expect(drawnPixels(), 0);
    });

    test('the group offset moves the whole assembly', () {
      draw(head());
      final before = _centroidX(fb);

      filter.offset = const Vec3(0.4, 0, 0);
      draw(head());
      final after = _centroidX(fb);

      expect(after, greaterThan(before + 2),
          reason: 'dragging must move helmet, visor and face fill together');
    });

    test('renders within a frame budget', () {
      draw(head()); // warm up
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        draw(head());
      }
      sw.stop();
      final perFrameMs = sw.elapsedMilliseconds / 10;
      expect(perFrameMs, lessThan(300), reason: '${perFrameMs}ms per frame');
    });
  });
}

/// Mean X of the painted pixels — enough to detect a horizontal shift.
double _centroidX(Framebuffer fb) {
  var sum = 0.0, n = 0;
  for (var y = 0; y < fb.height; y++) {
    for (var x = 0; x < fb.width; x++) {
      if (fb.color[(y * fb.width + x) * 4 + 3] > 0) {
        sum += x;
        n++;
      }
    }
  }
  return n == 0 ? 0 : sum / n;
}
