// Tests for demos/threejs/matrix.
//
// Two halves. The rain is synthesised rather than decoded, so its tests are
// about behaviour a viewer would notice — it falls, it fades behind the head,
// it fills the screen, it does not blow out. The mask shader is a straight
// transcription, so its tests pin the shader's arithmetic: the neck fade, the
// silhouette fade, the green key, and the seam that has to be invisible.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

// Plain `test`, matching tiger_test.dart — nothing here needs a widget binding
// beyond asset loading.

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

/// Shades one fragment. Defaults describe a point dead centre of the face:
/// facing the camera, well above the neck.
Float64List shade(
  MatrixMaskMaterial m, {
  double nx = 0,
  double ny = 0,
  double nz = 1,
  double oy = 0,
  double u = 0.5,
  double v = 0.5,
}) {
  final f = Fragment()
    ..nx = nx
    ..ny = ny
    ..nz = nz
    ..oy = oy
    ..vpU = u
    ..vpV = v;
  final out = Float64List(4);
  expect(m.shade(f, out), isTrue, reason: 'the mask is opaque and always draws');
  return out;
}

/// A flat rain texture of one colour, so the mask's own arithmetic is what
/// moves.
Texture2D flatRain(double r, double g, double b) {
  final px = Uint8List(4 * 4 * 4);
  for (var i = 0; i < 16; i++) {
    px[i * 4] = (r * 255).round();
    px[i * 4 + 1] = (g * 255).round();
    px[i * 4 + 2] = (b * 255).round();
    px[i * 4 + 3] = 255;
  }
  return Texture2D(4, 4, px);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MatrixRain', () {
    test('has the size its cells imply', () {
      final r = MatrixRain(columns: 10, rows: 12, cellWidth: 6, cellHeight: 10);
      expect(r.width, 60);
      expect(r.height, 120);
      expect(r.texture.width, 60);
      expect(r.texture.height, 120);
    });

    test('is opaque and mostly dark', () {
      final r = MatrixRain()..update(2.0);
      final px = _pixels(r);

      for (var i = 3; i < px.length; i += 4) {
        expect(px[i], 255, reason: 'the rain is a background, never see-through');
      }

      var lit = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] + px[i + 1] + px[i + 2] > 24) lit++;
      }
      final fraction = lit / (r.width * r.height);
      expect(fraction, greaterThan(0.02), reason: 'something must be falling');
      expect(fraction, lessThan(0.6), reason: 'mostly black, or it is not rain');
    });

    test('is green', () {
      final r = MatrixRain()..update(3.0);
      final px = _pixels(r);
      var sumR = 0, sumG = 0, sumB = 0;
      for (var i = 0; i < px.length; i += 4) {
        sumR += px[i];
        sumG += px[i + 1];
        sumB += px[i + 2];
      }
      expect(sumG, greaterThan(sumR * 3));
      expect(sumG, greaterThan(sumB * 3));
    });

    test('falls downward', () {
      // The centre of mass of the lit pixels moves down between two frames
      // early on, while the columns are still descending into an empty field.
      final r = MatrixRain(seed: 7)..update(0.35);
      final before = _centreOfMassY(r);
      r.update(0.35);
      final after = _centreOfMassY(r);
      expect(after, greaterThan(before), reason: '$before -> $after');
    });

    test('fades behind the leading glyph', () {
      // Walking up a lit column, brightness should fall off. Measured as the
      // mean of the brightest row versus rows well above it.
      final r = MatrixRain(seed: 3)..update(2.0);
      final rowMeans = _rowMeans(r);
      var peak = 0, peakRow = 0;
      for (var y = 0; y < rowMeans.length; y++) {
        if (rowMeans[y] > peak) {
          peak = rowMeans[y].round();
          peakRow = y;
        }
      }
      // Somewhere above the peak the trail must be dimmer than at the peak.
      final wellAbove = peakRow > 40 ? rowMeans[peakRow - 40] : rowMeans[0];
      expect(wellAbove, lessThan(peak.toDouble()));
    });

    test('keeps running and never blows out to white', () {
      final r = MatrixRain();
      for (var i = 0; i < 300; i++) {
        r.update(1 / 30);
      }
      final px = _pixels(r);
      var white = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] > 250 && px[i + 1] > 250 && px[i + 2] > 250) white++;
      }
      expect(white, 0, reason: 'columns overlap with max(), not add()');
      expect(r.elapsed, closeTo(10.0, 0.01));
    });

    test('columns recycle rather than emptying the screen', () {
      // After long enough for every column to have fallen off the bottom at
      // least once, the field must still be populated.
      final r = MatrixRain();
      for (var i = 0; i < 900; i++) {
        r.update(1 / 30);
      }
      final px = _pixels(r);
      var lit = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i + 1] > 24) lit++;
      }
      expect(lit, greaterThan(200), reason: 'the rain stopped');
    });

    test('rewrites one buffer in place rather than reallocating', () {
      final r = MatrixRain();
      final tex = r.texture;
      r.update(0.1);
      expect(identical(r.texture, tex), isTrue);
    });

    test('is deterministic for a given seed', () {
      final a = MatrixRain(seed: 42)..update(1.5);
      final b = MatrixRain(seed: 42)..update(1.5);
      expect(_pixels(a), _pixels(b));
      final c = MatrixRain(seed: 43)..update(1.5);
      expect(_pixels(a), isNot(c.texture.rgba));
    });

    test('a zero-length frame changes nothing', () {
      final r = MatrixRain()..update(1.0);
      final before = Uint8List.fromList(_pixels(r));
      r.update(0);
      expect(_pixels(r), before);
    });
  });

  group('the mask shader', () {
    test('adds the rain at full strength, un-attenuated', () {
      // `finalColor = colorCamera * isInsideFace + colorLineCode`.
      final m = MatrixMaskMaterial(rain: flatRain(0.1, 0.7, 0.2));
      final out = shade(m); // no camera yet, so colorCamera is black
      expect(out[0], closeTo(0.1, 0.01));
      expect(out[1], closeTo(0.7, 0.01));
      expect(out[2], closeTo(0.2, 0.01));
    });

    test('the silhouette dissolves into the background exactly', () {
      // The seam is the whole trick: at the edge, isInsideFace reaches 0 and
      // the refraction is mixed out, so the mask's pixel equals the plain
      // background sample. Any difference would draw a visible outline.
      final rain = flatRain(0.05, 0.6, 0.1);
      final m = MatrixMaskMaterial(
        rain: rain,
        video: video(16, 16, (u, v) => const [1.0, 1.0, 1.0]),
      );

      // Normal perpendicular to the view axis: pure silhouette.
      final edge = shade(m, nx: 1, ny: 0, nz: 0);
      final texel = Float64List(4);
      rain.sampleTopDown(0.5, 0.5, texel);
      expect(edge[0], closeTo(texel[0], 1e-9));
      expect(edge[1], closeTo(texel[1], 1e-9));
      expect(edge[2], closeTo(texel[2], 1e-9));
    });

    test('the neck dissolves the same way', () {
      final rain = flatRain(0.05, 0.6, 0.1);
      final m = MatrixMaskMaterial(
        rain: rain,
        video: video(16, 16, (u, v) => const [1.0, 1.0, 1.0]),
      );
      // Below -1.2 the smoothstep is 0, so isNeck is 1.
      final neck = shade(m, oy: -1.25);
      final face = shade(m, oy: 0.0);
      expect(neck[1], lessThan(face[1]));

      final texel = Float64List(4);
      rain.sampleTopDown(0.5, 0.5, texel);
      expect(neck[1], closeTo(texel[1], 1e-9));
    });

    test('the neck fade spans exactly -1.2 to -0.85', () {
      expect(MatrixMaskMaterial.kNeckLow, -1.2);
      expect(MatrixMaskMaterial.kNeckHigh, -0.85);
      final m = MatrixMaskMaterial(
        rain: flatRain(0, 0, 0),
        video: video(16, 16, (u, v) => const [1.0, 1.0, 1.0]),
      );
      // Monotone across the band.
      var last = -1.0;
      for (final y in const [-1.3, -1.2, -1.1, -1.0, -0.9, -0.85, -0.5]) {
        final g = shade(m, oy: y)[1];
        expect(g, greaterThanOrEqualTo(last - 1e-9), reason: 'at y=$y');
        last = g;
      }
    });

    test('keys the camera to green, over-driven', () {
      // colorCamera = luma * vec3(0, 1.5, 0). A mid-grey face at luma 0.2 is
      // below the specular threshold, so red and blue stay at zero.
      final m = MatrixMaskMaterial(
        rain: flatRain(0, 0, 0),
        video: video(16, 16, (u, v) => const [0.2, 0.2, 0.2]),
      );
      final out = shade(m);
      expect(out[0], closeTo(0.0, 1e-9), reason: 'no red at all');
      expect(out[2], closeTo(0.0, 1e-9), reason: 'no blue at all');
      expect(out[1], closeTo(0.2 * 1.5, 0.01));
      expect(MatrixMaskMaterial.kGreenGain, 1.5);
    });

    test('a bright face picks up a white specular kick', () {
      // `colorCamera += vec3(1.) * smoothstep(0.3, 0.6, colorCameraVal)`, so
      // above 0.6 luma the highlight is full white on top of the green.
      final rain = flatRain(0, 0, 0);
      final dim = MatrixMaskMaterial(
          rain: rain, video: video(16, 16, (u, v) => const [0.25, 0.25, 0.25]));
      final bright = MatrixMaskMaterial(
          rain: rain, video: video(16, 16, (u, v) => const [0.9, 0.9, 0.9]));

      expect(shade(dim)[0], closeTo(0.0, 1e-9), reason: 'below the threshold');
      expect(shade(bright)[0], closeTo(1.0, 0.01), reason: 'full white kick');
      expect(shade(bright)[2], closeTo(1.0, 0.01));
    });

    test('mirroring samples the other side of the camera', () {
      final rain = flatRain(0, 0, 0);
      final v = video(32, 32,
          (u, vv) => u < 0.5 ? const [0.9, 0.9, 0.9] : const [0.05, 0.05, 0.05]);
      final straight = MatrixMaskMaterial(rain: rain, video: v);
      final mirrored =
          MatrixMaskMaterial(rain: rain, video: v, mirrorVideo: true);
      expect(shade(straight, u: 0.2)[1], greaterThan(0.5));
      expect(shade(mirrored, u: 0.2)[1], lessThan(0.2));
    });

    test('refraction bends the rain lookup, but not head-on and not at the edge',
        () {
      // A horizontal ramp in the rain, so any UV shift shows as a colour shift.
      final px = Uint8List(64 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 64; x++) {
          final i = (y * 64 + x) * 4;
          px[i + 1] = (255 * x / 63).round();
          px[i + 3] = 255;
        }
      }
      final ramp = Texture2D(64, 4, px);
      final m = MatrixMaskMaterial(rain: ramp);

      // Head-on: refract() of a view-aligned normal has no xy, so no shift.
      final headOn = shade(m, nx: 0, ny: 0, nz: 1)[1];
      final texel = Float64List(4);
      ramp.sampleTopDown(0.5, 0.5, texel);
      expect(headOn, closeTo(texel[1], 1e-9));

      // Fully tangent: isInsideFace is 0, so the mix cancels the bend.
      final edge = shade(m, nx: 1, ny: 0, nz: 0)[1];
      expect(edge, closeTo(texel[1], 1e-9));

      // In between: the lookup really does move.
      final slanted = shade(m, nx: 0.45, ny: 0, nz: 0.893)[1];
      expect((slanted - texel[1]).abs(), greaterThan(0.01),
          reason: 'the code should flow across the face');
    });

    test('is opaque', () {
      final m = MatrixMaskMaterial(rain: flatRain(0, 0.5, 0));
      expect(m.transparent, isFalse);
      expect(shade(m)[3], 1.0);
    });
  });

  group('the filter', () {
    Future<(MatrixFilter, JeelizFaceFilterHelper, PerspectiveCamera)> build({
      int w = 240,
      int h = 320,
    }) async {
      final f = MatrixFilter();
      await f.load();
      final helper = JeelizFaceFilterHelper();
      final camera = helper.createCamera();
      helper.updateCamera(camera,
          canvasWidth: w.toDouble(),
          canvasHeight: h.toDouble(),
          videoWidth: w.toDouble(),
          videoHeight: h.toDouble());
      f.attach(helper);
      f.setVideo(video(64, 64, (u, v) => [u, u, u]));
      return (f, helper, camera);
    }

    test('loads the mask mesh at the demo\'s offset', () async {
      final (f, helper, _) = await build();
      expect(f.material, isNotNull);
      expect(f.needsVideo, isTrue);
      expect(f.needsVideoColor, isTrue);

      final mask = helper.faceObject.children.single as Mesh;
      expect(mask.position.x, 0.0);
      expect(mask.position.y, 0.3);
      expect(mask.position.z, -0.35);
      // 364 positions, 704 triangles, no normals in the file.
      expect(mask.geometry.positions.length, 364 * 3);
      expect(mask.geometry.indices.length, 2112);
      expect(mask.geometry.hasSuppliedNormals, isFalse);
    });

    test('preRender fills the whole framebuffer opaquely', () async {
      // The demo swaps the background quad's texture for the video, so the
      // camera is never shown. Every pixel must be covered.
      final (f, _, _) = await build();
      f.update(DetectState.lost, 1.5);

      final fb = Framebuffer(64, 96);
      fb.clear();
      f.preRender(fb);

      for (var i = 3; i < fb.color.length; i += 4) {
        expect(fb.color[i], 255);
      }
      var green = 0;
      for (var i = 1; i < fb.color.length; i += 4) {
        if (fb.color[i] > 24) green++;
      }
      expect(green, greaterThan(0), reason: 'the rain should be visible');
    });

    test('preRender leaves the depth buffer alone', () async {
      // The scene pass depends on the clear's 1.0.
      final (f, _, _) = await build();
      f.update(DetectState.lost, 1.0);
      final fb = Framebuffer(32, 32);
      fb.clear();
      f.preRender(fb);
      expect(fb.depth.every((d) => d == 1.0), isTrue);
    });

    test('the background still runs with no face detected', () async {
      // The demo's quad is not parented to the face object.
      final (f, helper, camera) = await build();
      f.update(DetectState.lost, 2.0);
      helper.update(const [DetectState.lost], camera);

      final fb = Framebuffer(80, 120);
      fb.clear();
      f.preRender(fb);
      SoftwareRenderer().render(helper.scene, camera, fb);

      var lit = 0;
      for (var i = 1; i < fb.color.length; i += 4) {
        if (fb.color[i] > 24) lit++;
      }
      expect(lit, greaterThan(0));
    });

    test('a detected face draws the mask over the rain', () async {
      final (f, helper, camera) = await build();
      const state =
          DetectState(detected: 1, x: 0, y: 0, s: 0.45, rx: 0, ry: 0, rz: 0);
      f.update(state, 1.5);
      helper.update(const [state], camera);

      final fb = Framebuffer(240, 320);
      fb.clear();
      f.preRender(fb);
      final before = Uint8List.fromList(fb.color);
      SoftwareRenderer().render(helper.scene, camera, fb);

      var changed = 0;
      for (var i = 0; i < fb.color.length; i += 4) {
        if (fb.color[i] != before[i] ||
            fb.color[i + 1] != before[i + 1] ||
            fb.color[i + 2] != before[i + 2]) {
          changed++;
        }
      }
      expect(changed, greaterThan(1000),
          reason: 'the head should be visible against the rain');
    });

    test('the rain advances with the filter', () async {
      final (f, _, _) = await build();
      f.update(DetectState.lost, 0.5);
      final a = Uint8List.fromList(f.rain.texture.rgba);
      f.update(DetectState.lost, 0.5);
      expect(f.rain.texture.rgba, isNot(a));
    });

    test('renders within a frame budget', () async {
      final (f, helper, camera) = await build(w: 270, h: 480);
      const state =
          DetectState(detected: 1, x: 0, y: 0, s: 0.45, rx: 0, ry: 0, rz: 0);
      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();

      for (var i = 0; i < 2; i++) {
        f.update(state, 1 / 30);
        helper.update(const [state], camera);
        fb.clear();
        f.preRender(fb);
        renderer.render(helper.scene, camera, fb);
      }

      final sw = Stopwatch()..start();
      const frames = 5;
      for (var i = 0; i < frames; i++) {
        f.update(state, 1 / 30);
        helper.update(const [state], camera);
        fb.clear();
        f.preRender(fb);
        renderer.render(helper.scene, camera, fb);
      }
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // ignore: avoid_print
      print('matrix: ${ms.toStringAsFixed(1)} ms/frame at 270x480 '
          '(${renderer.stats})');
      expect(ms, lessThan(600), reason: '${ms.toStringAsFixed(1)} ms/frame');
    });
  });
}

Uint8List _pixels(MatrixRain r) => r.texture.rgba;

double _centreOfMassY(MatrixRain r) {
  final px = _pixels(r);
  var sum = 0.0, weighted = 0.0;
  for (var y = 0; y < r.height; y++) {
    for (var x = 0; x < r.width; x++) {
      final g = px[(y * r.width + x) * 4 + 1].toDouble();
      sum += g;
      weighted += g * y;
    }
  }
  return sum == 0 ? 0 : weighted / sum;
}

List<double> _rowMeans(MatrixRain r) {
  final px = _pixels(r);
  return <double>[
    for (var y = 0; y < r.height; y++)
      () {
        var s = 0.0;
        for (var x = 0; x < r.width; x++) {
          s += px[(y * r.width + x) * 4 + 1];
        }
        return s / r.width;
      }(),
  ];
}
