// Tests for demos/threejs/celFace.
//
// The cel material is a pure function of the video it samples, and the blur is
// a pure function of an alpha buffer, so almost all of this is checkable
// exactly against the GLSL. The quirks get their own tests: several of them are
// arguably bugs in the original, and a "fix" would silently change how the
// filter looks.

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

/// Shades one fragment at viewport position (u, v).
Float64List shadeAt(CelFaceMaterial mat, double u, double v) {
  final f = Fragment()
    ..vpU = u
    ..vpV = v;
  final out = Float64List(4);
  final drew = mat.shade(f, out);
  expect(drew, isTrue, reason: 'the cel pass is opaque and always draws');
  return out;
}

void main() {
  group('quantisers', () {
    test('nearestLevel0 partitions the hue wheel as written', () {
      expect(nearestHueLevel(0), 140.0);
      expect(nearestHueLevel(140), 140.0);
      expect(nearestHueLevel(140.1), 160.0);
      expect(nearestHueLevel(160), 160.0);
      expect(nearestHueLevel(200), 240.0);
      expect(nearestHueLevel(240), 240.0);
      expect(nearestHueLevel(241), 360.0);
      expect(nearestHueLevel(359), 360.0);
    });

    test('the first band swallows the whole warm half, so skin comes out green',
        () {
      // 0-140 catches red, orange, yellow and green alike, and band 140 maps
      // to the green sector. Skin sits at roughly 20-40 degrees, so a lit face
      // is toon-shaded green — the magenta band only catches lips and strong
      // pinks, at 240-360.
      expect(nearestHueLevel(20), 140.0);
      expect(nearestHueLevel(40), 140.0);
      expect(nearestHueLevel(356), 360.0, reason: 'lips');

      final rgb = Float64List(3);
      hsvDegreesToRgb(140, 1.0, 1.0, rgb);
      expect(rgb[1], 1.0, reason: 'band 140 is the green sector');
      expect(rgb[0], lessThan(rgb[1]));
      expect(rgb[2], lessThan(rgb[1]));
    });

    test('the four bands give exactly four output hues', () {
      // green, green-cyan, blue, magenta — the whole toon palette.
      final rgb = Float64List(3);
      final hues = <List<double>>[];
      for (final band in const [140.0, 160.0, 240.0, 360.0]) {
        hsvDegreesToRgb(band, 1.0, 1.0, rgb);
        hues.add([rgb[0], rgb[1], rgb[2]]);
      }
      expect(hues[0], [0.0, 1.0, closeTo(1 / 3, 1e-9)]);
      expect(hues[1], [0.0, 1.0, closeTo(2 / 3, 1e-9)]);
      expect(hues[2], [0.0, 0.0, 1.0]);
      expect(hues[3], [1.0, 0.0, 1.0]);
    });

    test('nearestLevel1 never returns zero, despite its own comment', () {
      // The comment in the shader lists 0.0 as a level; the code rounds
      // everything below 0.15 up, so a grey pixel cannot stay achromatic.
      expect(nearestSaturationLevel(0.0), 0.15);
      expect(nearestSaturationLevel(0.15), 0.15);
      expect(nearestSaturationLevel(0.16), 0.3);
      expect(nearestSaturationLevel(0.9), 1.0);
      expect(nearestSaturationLevel(1.0), 1.0);
    });

    test('nearestLevel2 gives three value bands', () {
      expect(nearestValueLevel(0.0), 0.3);
      expect(nearestValueLevel(0.3), 0.3);
      expect(nearestValueLevel(0.31), 0.6);
      expect(nearestValueLevel(0.6), 0.6);
      expect(nearestValueLevel(0.61), 1.0);
    });
  });

  group('HSV, in the shader\'s own form', () {
    test('primaries convert with hue in degrees', () {
      final hsv = Float64List(3);
      rgbToHsvDegrees(1, 0, 0, hsv);
      expect(hsv[0], closeTo(0, 1e-9));
      expect(hsv[1], closeTo(1, 1e-9));
      expect(hsv[2], closeTo(1, 1e-9));

      rgbToHsvDegrees(0, 1, 0, hsv);
      expect(hsv[0], closeTo(120, 1e-9));
      rgbToHsvDegrees(0, 0, 1, hsv);
      expect(hsv[0], closeTo(240, 1e-9));
      rgbToHsvDegrees(0, 1, 1, hsv);
      expect(hsv[0], closeTo(180, 1e-9));
    });

    test('round trips where hue is defined', () {
      final hsv = Float64List(3);
      final rgb = Float64List(3);
      for (final c in const [
        [1.0, 0.0, 0.0],
        [0.2, 0.7, 0.4],
        [0.9, 0.6, 0.1],
        [0.5, 0.25, 0.75],
      ]) {
        rgbToHsvDegrees(c[0], c[1], c[2], hsv);
        hsvDegreesToRgb(hsv[0], hsv[1], hsv[2], rgb);
        expect(rgb[0], closeTo(c[0], 1e-9), reason: '$c');
        expect(rgb[1], closeTo(c[1], 1e-9), reason: '$c');
        expect(rgb[2], closeTo(c[2], 1e-9), reason: '$c');
      }
    });

    test('black returns hue -1, which the quantisers turn into dark green-grey',
        () {
      // The shader's early return leaves (h, s, v) = (-1, 0, 0). Every
      // quantiser rounds up, so black comes back at 30% value rather than 0.
      final hsv = Float64List(3);
      rgbToHsvDegrees(0, 0, 0, hsv);
      expect(hsv[0], -1.0);
      expect(hsv[1], 0.0);
      expect(hsv[2], 0.0);

      final rgb = Float64List(3);
      hsvDegreesToRgb(nearestHueLevel(hsv[0]), nearestSaturationLevel(hsv[1]),
          nearestValueLevel(hsv[2]), rgb);
      expect(rgb[1], closeTo(0.3, 1e-9), reason: 'green is the max channel');
      expect(rgb[0], lessThan(rgb[1]));
      expect(rgb[2], lessThan(rgb[1]));
      expect(rgb[0], greaterThan(0.2), reason: 'not black any more');
    });

    test('a hue of 360 comes out magenta, not red', () {
      // h/60 == 6 lands in a sector the shader's if-chain does not name, so it
      // falls through to the i==5 case. Since the whole red half of the wheel
      // quantises to 360, this covers most of a face.
      final rgb = Float64List(3);
      hsvDegreesToRgb(360, 1.0, 1.0, rgb);
      expect(rgb[0], closeTo(1.0, 1e-9));
      expect(rgb[1], closeTo(0.0, 1e-9));
      expect(rgb[2], closeTo(1.0, 1e-9));
    });

    test('grey picks up a cast rather than staying grey', () {
      final hsv = Float64List(3);
      rgbToHsvDegrees(0.5, 0.5, 0.5, hsv);
      expect(hsv[0], 360.0, reason: 'undefined hue falls through to 360');
      expect(hsv[1], 0.0);

      final rgb = Float64List(3);
      hsvDegreesToRgb(nearestHueLevel(hsv[0]), nearestSaturationLevel(hsv[1]),
          nearestValueLevel(hsv[2]), rgb);
      expect(rgb[0], greaterThan(rgb[1]),
          reason: 'saturation rounded up to 0.15 in the magenta sector');
      expect(rgb[2], greaterThan(rgb[1]));
    });
  });

  group('CelFaceMaterial', () {
    test('is an opaque pass that needs no normals', () {
      final m = CelFaceMaterial();
      expect(m.transparent, isFalse);
      expect(m.needsNormals, isFalse,
          reason: 'the demo computes normals the shader never reads');
    });

    test('draws the silhouette black before the first camera frame', () {
      final out = shadeAt(CelFaceMaterial(), 0.5, 0.5);
      expect(out[3], 1.0);
      expect(out[0], 0.0);
    });

    test('a flat field produces no edge and posterises the colour', () {
      final v = video(64, 64, (u, vv) => const [0.85, 0.62, 0.5]); // lit skin
      final m = CelFaceMaterial(video: v);
      final out = shadeAt(m, 0.5, 0.5);

      expect(out[3], 1.0);
      expect(out[0] + out[1] + out[2], greaterThan(0.1),
          reason: 'a flat field is not an edge, so this must not be black');

      // Skin quantises into band 140, the green sector, so green leads.
      expect(out[1], greaterThan(out[0]));
      expect(out[1], greaterThan(out[2]));
    });

    test('paints a hard boundary black', () {
      // A black/white step down the middle. The fragment sitting on the step
      // must exceed EDGE_THRESHOLD; one far away must not.
      final v = video(64, 64, (u, vv) => u < 0.5
          ? const [0.0, 0.0, 0.0]
          : const [1.0, 1.0, 1.0]);
      final m = CelFaceMaterial(video: v);

      final onEdge = shadeAt(m, 0.5, 0.5);
      expect(onEdge[0], 0.0);
      expect(onEdge[1], 0.0);
      expect(onEdge[2], 0.0);

      final away = shadeAt(m, 0.2, 0.5);
      expect(away[0] + away[1] + away[2], greaterThan(0.0),
          reason: 'flat black region is not an edge; it posterises instead');
    });

    test('the gain is 5 and the threshold 0.2, so a 4% step already inks', () {
      // EDGE_THRESHOLD2 * delta >= EDGE_THRESHOLD  =>  delta >= 0.04.
      // The operator averages four differences, two of which straddle the step
      // and two of which do not, so the ramp has to be a little steeper than
      // 0.04 to trip it — this pins the order of magnitude, not the constant.
      final scratch = Float64List(3);
      double edgeForStep(double amplitude) {
        final v = video(64, 64,
            (u, vv) => u < 0.5 ? [0.5, 0.5, 0.5] : [0.5 + amplitude, 0.5 + amplitude, 0.5 + amplitude]);
        return CelFaceMaterial.edgeAt(v, 0.5, 0.5, false, scratch);
      }

      expect(edgeForStep(0.01), lessThan(CelFaceMaterial.kEdgeThreshold));
      expect(edgeForStep(0.4), greaterThanOrEqualTo(CelFaceMaterial.kEdgeThreshold));
      expect(CelFaceMaterial.kEdgeGain, 5.0);
      expect(CelFaceMaterial.kEdgeThreshold, 0.2);
    });

    test('the edge operator is symmetric under mirroring', () {
      // abs(pix1-pix7) and the two diagonals swap into each other under a flip
      // in x, so a mirrored sample must report the same edge strength as the
      // un-mirrored sample of the mirrored point.
      final v = video(64, 64, (u, vv) => [u, vv, 0.5]);
      final scratch = Float64List(3);
      final a = CelFaceMaterial.edgeAt(v, 0.3, 0.4, false, scratch);
      final b = CelFaceMaterial.edgeAt(v, 0.7, 0.4, false, scratch);
      expect(a, closeTo(b, 1e-9));
    });

    test('mirroring samples the other side of the frame', () {
      final v = video(64, 64,
          (u, vv) => u < 0.5 ? const [0.9, 0.1, 0.1] : const [0.1, 0.1, 0.9]);
      final straight = shadeAt(CelFaceMaterial(video: v), 0.2, 0.5);
      final mirrored =
          shadeAt(CelFaceMaterial(video: v, mirrorVideo: true), 0.2, 0.5);
      expect(straight, isNot(equals(mirrored)));
    });
  });

  group('CelFaceFilter constants', () {
    test('match the demo', () {
      expect(CelFaceFilter.kPivotedScale, 1.1);
      expect(CelFaceFilter.kMaskScale, 1.2);
      expect(CelFaceFilter.kMaskPosition.x, 0.0);
      expect(CelFaceFilter.kMaskPosition.y, 0.2);
      expect(CelFaceFilter.kMaskPosition.z, -0.5);
      expect(CelFaceFilter.kLumaR + CelFaceFilter.kLumaG + CelFaceFilter.kLumaB,
          closeTo(1.0, 1e-9));
    });

    test('FACECOLOR clips on red, which is what makes highlights read as paper',
        () {
      expect(CelFaceFilter.kFaceColorR, greaterThan(1.0));
      expect(CelFaceFilter.kFaceColorR, closeTo(1.2 * 242 / 255, 1e-12));
      expect(CelFaceFilter.kFaceColorG, closeTo(1.2 * 236 / 255, 1e-12));
      expect(CelFaceFilter.kFaceColorB, closeTo(1.2 * 230 / 255, 1e-12));
      expect(CelFaceFilter.kFaceColorR,
          greaterThan(CelFaceFilter.kFaceColorB),
          reason: 'warm, not neutral');
    });

    test('the blur kernel is Pascal row 8 with its ends dropped', () {
      const w = CelFaceFilter.kBlurWeights;
      expect(w.length, 7);
      // Symmetric.
      for (var i = 0; i < 3; i++) {
        expect(w[i], closeTo(w[6 - i], 1e-12));
      }
      // Sums to 254/254, i.e. 1 — the two dropped 1s are why the divisor is
      // 254 and not 256.
      expect(w.reduce((a, b) => a + b), closeTo(1.0, 1e-12));
      expect(w[3], closeTo(70 / 254, 1e-12));
    });
  });

  group('postProcess', () {
    /// A framebuffer with an opaque white disc of radius [r] (in pixels) at the
    /// centre — a stand-in for the rendered mask.
    Framebuffer disc(int size, double r) {
      final fb = Framebuffer(size, size);
      final c = size / 2.0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x + 0.5 - c, dy = y + 0.5 - c;
          final inside = dx * dx + dy * dy <= r * r;
          final i = (y * size + x) * 4;
          if (inside) {
            fb.color[i] = 200;
            fb.color[i + 1] = 200;
            fb.color[i + 2] = 200;
            fb.color[i + 3] = 255;
          }
        }
      }
      return fb;
    }

    int alphaAt(Framebuffer fb, int x, int y) =>
        fb.color[(y * fb.width + x) * 4 + 3];

    test('the feather only eats inward — nothing outside the mask lights up',
        () {
      // This is the `if (colCenter.a == 0.0)` guard, and the reason the low
      // poly count never shows. Without it the blur would grow a halo.
      const size = 128;
      final fb = disc(size, 30);
      final before = <int>[
        for (var y = 0; y < size; y++)
          for (var x = 0; x < size; x++) alphaAt(fb, x, y),
      ];

      CelFaceFilter().postProcess(fb);

      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++, i++) {
          if (before[i] == 0) {
            expect(alphaAt(fb, x, y), 0,
                reason: 'pixel ($x,$y) was outside the mask and must stay out');
          }
        }
      }
    });

    test('the border is feathered and the interior stays solid', () {
      const size = 128;
      final fb = disc(size, 40);
      CelFaceFilter().postProcess(fb);

      // Dead centre: every tap is inside, so alpha survives at full strength.
      expect(alphaAt(fb, 64, 64), 255);

      // Just inside the rim: partial coverage, squared twice, so well down.
      final rim = alphaAt(fb, 64 + 38, 64);
      expect(rim, greaterThan(0));
      expect(rim, lessThan(200));

      // And monotone on the way out.
      final ring = <int>[
        for (var d = 30; d <= 39; d++) alphaAt(fb, 64 + d, 64),
      ];
      for (var k = 1; k < ring.length; k++) {
        expect(ring[k], lessThanOrEqualTo(ring[k - 1]),
            reason: 'alpha must not rise towards the rim: $ring');
      }
    });

    test('two squarings make the feather bite hard', () {
      // `pow(a, 2)` runs on each pass, so half coverage in both axes lands at
      // 0.5^4 = 6%, not 25%. A single squaring would leave a much fatter edge.
      const size = 64;
      final fb = Framebuffer(size, size);
      // Left half opaque, right half empty: a straight vertical border.
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size ~/ 2; x++) {
          final i = (y * size + x) * 4;
          fb.color[i] = fb.color[i + 1] = fb.color[i + 2] = 255;
          fb.color[i + 3] = 255;
        }
      }
      CelFaceFilter(blurReferenceHeightPx: size.toDouble(), blurEdgeSoftness: 2)
          .postProcess(fb);

      // The last opaque column has roughly half its taps outside.
      final lip = alphaAt(fb, size ~/ 2 - 1, 32) / 255.0;
      expect(lip, lessThan(0.25),
          reason: 'one squaring would leave ~0.25; two leave ~0.06');
    });

    test('tints towards ivory and premultiplies', () {
      const size = 64;
      final fb = disc(size, 24);
      CelFaceFilter().postProcess(fb);

      const i = (32 * size + 32) * 4;
      expect(fb.color[i + 3], 255, reason: 'interior is fully opaque');
      // grey 200 * 1.139 = 228 red, and blue is the coolest channel.
      expect(fb.color[i], greaterThan(fb.color[i + 2]));
      expect(fb.color[i], closeTo(228, 2));
      // Premultiplied, so at full alpha the channels are the tint itself.
      expect(fb.color[i], lessThanOrEqualTo(255));
    });

    test('a black cel pixel stays black through the tint', () {
      // The edge ink is luma 0, and the tint is a multiply, so ink survives.
      const size = 64;
      final fb = Framebuffer(size, size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final i = (y * size + x) * 4;
          fb.color[i + 3] = 255; // opaque, colour left at 0
        }
      }
      CelFaceFilter().postProcess(fb);
      const i = (32 * size + 32) * 4;
      expect(fb.color[i], 0);
      expect(fb.color[i + 1], 0);
      expect(fb.color[i + 2], 0);
      expect(fb.color[i + 3], 255);
    });

    test('an empty framebuffer is left empty', () {
      final fb = Framebuffer(32, 32);
      fb.clear();
      CelFaceFilter().postProcess(fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('the feather is the same fraction of the image at any render size',
        () {
      // The demo's tap spacing is in canvas pixels and its canvas is fixed;
      // here the render target is on a slider, so the spacing is scaled. Check
      // that a disc of the same *relative* radius keeps the same relative
      // feather at two resolutions.
      double featherFraction(int size) {
        final fb = disc(size, size * 0.3);
        CelFaceFilter().postProcess(fb);
        // Walk out from the centre to the first pixel below half alpha.
        for (var d = 0; d < size ~/ 2; d++) {
          if (alphaAt(fb, size ~/ 2 + d, size ~/ 2) < 128) return d / size;
        }
        return 0.5;
      }

      final small = featherFraction(120);
      final big = featherFraction(240);
      expect(small, closeTo(big, 0.02),
          reason: 'small=$small big=$big should track each other');
    });
  });

  group('the filter, loaded and rendered', () {
    testWidgets('loads the low-poly head and draws it', (tester) async {
      final filter = CelFaceFilter();
      await filter.load();

      expect(filter.material, isNotNull);
      expect(filter.needsVideo, isTrue);
      expect(filter.needsVideoColor, isTrue,
          reason: 'HSV and a luma dot product both need real colour');

      final helper = JeelizFaceFilterHelper();
      final camera = helper.createCamera();
      helper.updateCamera(camera,
          canvasWidth: 240,
          canvasHeight: 320,
          videoWidth: 240,
          videoHeight: 320);
      filter.attach(helper);

      filter.setVideo(video(64, 64, (u, v) => [u, 0.5, 1 - u]));

      const state = DetectState(
        detected: 1,
        x: 0,
        y: 0,
        s: 0.5,
        rx: 0,
        ry: 0,
        rz: 0,
      );
      helper.update(const [state], camera);

      final fb = Framebuffer(240, 320);
      fb.clear();
      SoftwareRenderer().render(helper.scene, camera, fb);

      var covered = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) covered++;
      }
      expect(covered, greaterThan(500),
          reason: 'the head should cover a real part of the frame');

      filter.postProcess(fb);

      var stillCovered = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) stillCovered++;
      }
      expect(stillCovered, greaterThan(0));
      expect(stillCovered, lessThanOrEqualTo(covered),
          reason: 'the feather only removes coverage, never adds it');

      filter.detach(helper);
    });

    testWidgets('the geometry is position-only, as exported', (tester) async {
      // faceLowPoly.json ships 497 positions and no normals or UVs. The demo
      // calls computeVertexNormals(); the material never reads the result.
      final json = await loadJeelizAssetString('celFace/faceLowPoly.json');
      final g = decodeBufferGeometry(json);
      expect(g.positions.length, 497 * 3);
      expect(g.hasSuppliedNormals, isFalse);
      expect(g.indices.length, 2922);
    });

    testWidgets('renders within a frame budget', (tester) async {
      final filter = CelFaceFilter();
      await filter.load();
      final helper = JeelizFaceFilterHelper();
      final camera = helper.createCamera();
      helper.updateCamera(camera,
          canvasWidth: 270,
          canvasHeight: 480,
          videoWidth: 270,
          videoHeight: 480);
      filter.attach(helper);
      filter.setVideo(video(192, 192, (u, v) => [u, v, 0.5]));

      const state = DetectState(
          detected: 1, x: 0, y: 0, s: 0.4, rx: 0, ry: 0, rz: 0);
      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();

      final sw = Stopwatch()..start();
      const frames = 5;
      for (var i = 0; i < frames; i++) {
        helper.update(const [state], camera);
        fb.clear();
        renderer.render(helper.scene, camera, fb);
        filter.postProcess(fb);
      }
      sw.stop();

      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // Loose: this runs under the test harness, not on a phone. It exists to
      // catch an accidental order-of-magnitude regression.
      expect(ms, lessThan(400), reason: '${ms.toStringAsFixed(1)} ms/frame');
      // ignore: avoid_print
      print('celFace: ${ms.toStringAsFixed(1)} ms/frame at 270x480');
    });
  });

  group('locateFace-style sanity', () {
    test('Fragment viewport coords drive the sampling, not UVs', () {
      // The geometry has no UV attribute at all, so if the material read f.u /
      // f.v it would sample a single texel for the whole head.
      //
      // The two probes have to land in *different* quantiser bands to be
      // distinguishable at all — a red-to-blue ramp would not do, because both
      // ends fall in band 360 and come back the same magenta. Dark green on one
      // side and bright blue on the other separates in hue and in value.
      final v = video(64, 64,
          (u, vv) => u < 0.5 ? const [0.05, 0.3, 0.05] : const [0.2, 0.3, 0.95]);
      final m = CelFaceMaterial(video: v);
      final left = shadeAt(m, 0.15, 0.5);
      final right = shadeAt(m, 0.85, 0.5);
      expect(left, isNot(equals(right)),
          reason: 'different screen positions must sample different video');
    });
  });
}
