// Tests for demos/threejs/halloween_spider.
//
// This is the first ported filter that waits for you — nothing moves until the
// mouth opens — so most of these tests are about the trigger and the one-shot
// playback around it. The rest pin the four dead things the demo carries, since
// each is exactly the sort of thing a port would "restore" into looking wrong.

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

DetectState head({double mouth = 0, double detected = 1}) => DetectState(
      detected: detected,
      x: 0,
      y: 0,
      s: 0.4,
      rx: 0,
      ry: 0,
      rz: 0,
      expressions: [mouth],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Loading two 5.6 MB models with 121 morph frames each is slow, so it is
  // done once and the scene rebuilt per test.
  late HalloweenSpiderFilter shared;
  setUpAll(() async {
    shared = HalloweenSpiderFilter(showFrame: false, textureMaxWidth: 64);
    await shared.load();
  });

  Future<(HalloweenSpiderFilter, JeelizFaceFilterHelper, PerspectiveCamera)>
      build({bool frame = false, int stride = 8}) async {
    final f = HalloweenSpiderFilter(
        showFrame: frame, textureMaxWidth: 64, morphStride: stride);
    await f.load();
    final helper = JeelizFaceFilterHelper();
    final camera = helper.createCamera();
    helper.updateCamera(camera,
        canvasWidth: 240, canvasHeight: 320, videoWidth: 240, videoHeight: 320);
    f.attach(helper);
    f.setVideo(video(64, 64, (u, v) => [u, 0.5, 1 - u]));
    return (f, helper, camera);
  }

  /// Feeds [frames] update calls with the mouth at [mouth].
  void pump(HalloweenSpiderFilter f, int frames, {double mouth = 0}) {
    for (var i = 0; i < frames; i++) {
      f.update(head(mouth: mouth), 1 / 30);
    }
  }

  /// The index of the strongest morph influence, or -1 if all are zero.
  int activeFrame(Mesh m) {
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

  group('the scene', () {
    test('is two spiders and a face, on one scaled group', () async {
      final helper = JeelizFaceFilterHelper();
      shared.attach(helper);

      final root = helper.faceObject.children.single;
      expect(root.scale.x, closeTo(0.59, 1e-12));
      expect(root.position.y, closeTo(0.4, 1e-12));
      expect(root.position.z, closeTo(-0.5, 1e-12));
      expect(root.children.length, 3);
      expect(root.children.map((c) => c.name),
          containsAll(<String>['spiderFace', 'smallSpider', 'bigSpider']));

      shared.detach(helper);
    });

    test('only the small spider is offset', () async {
      // `smallSpiderMesh.position.y -= 0.2`; the big spider's equivalent line
      // is commented out.
      final helper = JeelizFaceFilterHelper();
      shared.attach(helper);
      final root = helper.faceObject.children.single;
      final small =
          root.children.firstWhere((c) => c.name == 'smallSpider');
      final big = root.children.firstWhere((c) => c.name == 'bigSpider');
      expect(small.position.y, closeTo(-0.2, 1e-12));
      expect(big.position.y, 0.0);
      shared.detach(helper);
    });

    test('the two spiders are different meshes sharing one texture', () async {
      // Same face and vertex counts, but the models genuinely differ — they
      // are not one mesh at two scales.
      final helper = JeelizFaceFilterHelper();
      shared.attach(helper);
      final a = shared.spiders[0], b = shared.spiders[1];

      expect(a.geometry.positions.length, b.geometry.positions.length);
      expect(a.geometry.positions, isNot(b.geometry.positions));

      final ma = a.materials.single as BasicColorMaterial;
      final mb = b.materials.single as BasicColorMaterial;
      expect(identical(ma.map, mb.map), isTrue,
          reason: 'diffuse_spider.jpg is byte-identical in both directories');
      shared.detach(helper);
    });

    test('the spiders are unlit, so the demo\'s two lights are inert',
        () async {
      // MeshBasicMaterial ignores lights, and the face uses a custom shader.
      // The demo adds an AmbientLight and a SpotLight regardless.
      final helper = JeelizFaceFilterHelper();
      shared.attach(helper);
      for (final s in shared.spiders) {
        expect(s.materials.single, isA<BasicColorMaterial>());
        expect(s.materials.single.needsNormals, isFalse);
      }

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
      expect(lights, 0);
      shared.detach(helper);
    });

    test('each spider carries 121 morph frames', () async {
      final helper = JeelizFaceFilterHelper();
      shared.attach(helper);
      for (final s in shared.spiders) {
        expect(s.geometry.morphPositions.length, 121);
        expect(s.morphInfluences.length, 121);
        expect(s.geometry.morphPositions.first.length,
            s.geometry.positions.length);
      }
      shared.detach(helper);
    });

    test('morphStride thins the frames without touching anything else',
        () async {
      final (f, _, _) = await build(stride: 8);
      // ceil(121 / 8) = 16.
      expect(f.spiders.first.geometry.morphPositions.length, 16);
      expect(f.spiders.first.morphInfluences.length, 16);
    });
  });

  group('the face mesh', () {
    test('redraws the camera opaquely, with both coefficients dead', () async {
      // `gl_FragColor = vec4(videoColor, 1)` — darkenCoeff and borderCoeff are
      // computed and never used, so this is rupy_helmet's shader with the
      // payload removed.
      final m = SpiderFaceMaterial(
          video: video(8, 8, (u, v) => const [0.25, 0.5, 0.75]));
      final f = Fragment()
        ..vpU = 0.5
        ..vpV = 0.5
        // A normal pointing away from the camera and a y below the jaw: under
        // rupy's shader both would fade this fragment out. Here neither does.
        ..nx = 1
        ..ny = 0
        ..nz = 0
        ..oy = -1.0;
      final out = Float64List(4);

      expect(m.shade(f, out), isTrue);
      expect(out[0], closeTo(0.25, 0.01));
      expect(out[1], closeTo(0.5, 0.01));
      expect(out[2], closeTo(0.75, 0.01));
      expect(out[3], 1.0, reason: 'never faded at the silhouette');
    });

    test('reads no normal', () async {
      expect(SpiderFaceMaterial().needsNormals, isFalse);
    });

    test('mirroring samples the other side', () async {
      final v = video(32, 32,
          (u, vv) => u < 0.5 ? const [0.9, 0.1, 0.1] : const [0.1, 0.1, 0.9]);
      final out = Float64List(4);
      final f = Fragment()
        ..vpU = 0.2
        ..vpV = 0.5;

      SpiderFaceMaterial(video: v).shade(f, out);
      expect(out[0], greaterThan(out[2]));
      SpiderFaceMaterial(video: v, mirrorVideo: true).shade(f, out);
      expect(out[2], greaterThan(out[0]));
    });

    test('is black before the first camera frame', () async {
      final out = Float64List(4);
      SpiderFaceMaterial().shade(Fragment(), out);
      expect(out[0], 0.0);
      expect(out[3], 1.0);
    });

    test('the filter needs colour video for it', () async {
      expect(shared.needsVideo, isTrue);
      expect(shared.needsVideoColor, isTrue);
    });
  });

  group('the mouth trigger', () {
    test('nothing moves with the mouth closed', () async {
      final (f, _, _) = await build();
      pump(f, 60, mouth: 0.0);
      expect(f.isAnimating, isFalse);
      for (final s in f.spiders) {
        expect(activeFrame(s), -1, reason: 'no influence at all');
      }
    });

    test('a half-open mouth is not enough', () async {
      // The threshold is 0.8.
      final (f, _, _) = await build();
      pump(f, 30, mouth: 0.79);
      expect(f.isAnimating, isFalse);
      pump(f, 2, mouth: 0.8);
      expect(f.isAnimating, isTrue);
    });

    test('opening the mouth starts both spiders together', () async {
      final (f, _, _) = await build();
      pump(f, 3, mouth: 0.9);
      expect(f.isAnimating, isTrue);
      expect(activeFrame(f.spiders[0]), greaterThanOrEqualTo(0));
      expect(activeFrame(f.spiders[0]), activeFrame(f.spiders[1]),
          reason: 'one clock drives both');
    });

    test('holding the mouth open does not retrigger', () async {
      // `isAnimating` guards it. Without the guard the clip would restart
      // every frame and never advance.
      final (f, _, _) = await build();
      pump(f, 5, mouth: 1.0);
      final early = activeFrame(f.spiders.first);
      pump(f, 5, mouth: 1.0);
      expect(activeFrame(f.spiders.first), greaterThan(early));
    });

    test('it plays once and stops, rather than looping', () async {
      // The demo gets this by letting three loop and catching the 'loop'
      // event. At full length the clip is 121 frames at 10 fps — 12.1 s — and
      // the fixed 0.08 s step gets through it in about 152 rendered frames.
      final (f, _, _) = await build(stride: 1);
      expect(f.spiders.first.morphInfluences.length, 121);

      pump(f, 3, mouth: 1.0);
      expect(f.isAnimating, isTrue);

      pump(f, 140, mouth: 0.0);
      expect(f.isAnimating, isTrue, reason: 'still mid-clip at ~143 frames');

      pump(f, 20, mouth: 0.0);
      expect(f.isAnimating, isFalse, reason: 'played through and reset');
      for (final s in f.spiders) {
        expect(activeFrame(s), -1, reason: 'influences cleared on stop');
      }
    });

    test('it can be triggered again after it finishes', () async {
      final (f, _, _) = await build(stride: 1);
      pump(f, 3, mouth: 1.0);
      pump(f, 200, mouth: 0.0);
      expect(f.isAnimating, isFalse);

      pump(f, 3, mouth: 1.0);
      expect(f.isAnimating, isTrue);
      expect(activeFrame(f.spiders.first), greaterThanOrEqualTo(0));
    });

    test('losing the face freezes it where it was', () async {
      // The demo wraps both the trigger and `mixer.update` in `if (ISDETECTED)`.
      final (f, _, _) = await build();
      pump(f, 10, mouth: 1.0);
      final at = activeFrame(f.spiders.first);

      for (var i = 0; i < 40; i++) {
        f.update(head(detected: 0), 1 / 30);
      }
      expect(activeFrame(f.spiders.first), at, reason: 'frozen, not advanced');

      pump(f, 3, mouth: 0.0);
      expect(activeFrame(f.spiders.first), greaterThan(at),
          reason: 'and resumes where it left off');
    });

    test('an undetected face cannot trigger it', () async {
      final (f, _, _) = await build();
      for (var i = 0; i < 20; i++) {
        f.update(head(mouth: 1.0, detected: 0), 1 / 30);
      }
      expect(f.isAnimating, isFalse);
    });

    test('the step is fixed per frame, not per second', () async {
      // `mixer.update(0.08)` ignores real elapsed time, so the same frame
      // count lands on the same clip frame whatever dt says.
      final (a, _, _) = await build();
      final (b, _, _) = await build();
      for (var i = 0; i < 20; i++) {
        a.update(head(mouth: 1.0), 1 / 15);
        b.update(head(mouth: 1.0), 1 / 120);
      }
      expect(activeFrame(a.spiders.first), activeFrame(b.spiders.first));
      expect(HalloweenSpiderFilter.kMixerStepSeconds, 0.08);
    });

    test('only two adjacent influences are ever non-zero', () async {
      final (f, _, _) = await build(stride: 4);
      pump(f, 25, mouth: 1.0);
      for (final s in f.spiders) {
        final nz = <int>[];
        var total = 0.0;
        for (var i = 0; i < s.morphInfluences.length; i++) {
          if (s.morphInfluences[i] != 0) {
            nz.add(i);
            total += s.morphInfluences[i];
          }
        }
        expect(nz.length, inInclusiveRange(1, 2));
        expect(total, closeTo(1.0, 1e-9));
      }
    });
  });

  group('rendering', () {
    test('draws the face and the spiders', () async {
      final (f, helper, cam) = await build();
      helper.update([head()], cam);

      final fb = Framebuffer(240, 320);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);

      var lit = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) lit++;
      }
      expect(lit, greaterThan(1000));
    });

    test('an undetected face draws nothing', () async {
      final (f, helper, cam) = await build();
      pump(f, 10, mouth: 1.0);
      helper.update(const [DetectState.lost], cam);
      final fb = Framebuffer(160, 240);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('the frame is a full-screen foreground', () async {
      final f = HalloweenSpiderFilter(textureMaxWidth: 32, morphStride: 32);
      await f.load();
      expect(f.foreground, isNotNull);
      expect(f.foregroundLayout, ForegroundLayout.fill);
    });

    test('detach clears the scene', () async {
      final (f, helper, _) = await build();
      expect(helper.faceObject.children, isNotEmpty);
      f.detach(helper);
      expect(helper.faceObject.children, isEmpty);
      expect(f.spiders, isEmpty);
      expect(f.isAnimating, isFalse);
    });

    test('renders within a frame budget mid-animation', () async {
      final (f, helper, cam) = await build(stride: 1);
      pump(f, 40, mouth: 1.0);

      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();
      final state = head();
      for (var i = 0; i < 2; i++) {
        f.update(state, 1 / 30);
        helper.update([state], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }

      final sw = Stopwatch()..start();
      const frames = 5;
      for (var i = 0; i < frames; i++) {
        f.update(state, 1 / 30);
        helper.update([state], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // ignore: avoid_print
      print('halloweenSpider: ${ms.toStringAsFixed(1)} ms/frame at 270x480 '
          '(${renderer.stats})');
      expect(ms, lessThan(1500), reason: '${ms.toStringAsFixed(1)} ms/frame');
    });
  });
}
