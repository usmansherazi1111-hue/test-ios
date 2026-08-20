// Tests for the art-painting face swap (demos/faceReplacement/image).
//
// Everything here is pure computation — no camera, no decoding — so the
// geometry and the colour transform can be checked exactly against the
// original's arithmetic.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

/// A [Texture2D] painted by a callback taking normalised, top-down uv.
Texture2D texture(int w, int h, List<double> Function(double u, double v) f) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = f((x + 0.5) / w, (y + 0.5) / h);
      final i = (y * w + x) * 4;
      px[i] = (c[0] * 255).round().clamp(0, 255);
      px[i + 1] = (c[1] * 255).round().clamp(0, 255);
      px[i + 2] = (c[2] * 255).round().clamp(0, 255);
      px[i + 3] = 255;
    }
  }
  return Texture2D(w, h, px);
}

/// A colour video frame painted the same way.
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
      t.luma[y * w + x] =
          ((c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114) * 255).round().clamp(0, 255);
    }
  }
  return t;
}

/// Reads a pixel out of an RGBA buffer as 0..1 doubles.
List<double> pixel(Uint8List rgba, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return [rgba[i] / 255, rgba[i + 1] / 255, rgba[i + 2] / 255, rgba[i + 3] / 255];
}

void main() {
  const settings = ArtPaintingSettings();

  // ArtPainting demands a real ui.Image; the compositor never reads it, so a
  // 1x1 opaque pixel stands in.
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image dummyImage;
  setUpAll(() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(const [0, 0, 0, 255]));
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: 1, height: 1, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    dummyImage = (await codec.getNextFrame()).image;
    codec.dispose();
    descriptor.dispose();
  });

  group('FaceBox', () {
    test('reproduces the demo box formula for the Joconde', () {
      // build_artPaintingMask(), with the hard-coded state and a 4:3 painting:
      //   xn  = x*0.5 + 0.5 + s*maskOffset[0]*sin(ry)
      //   yn  = y*0.5 + 0.5 + s*maskOffset[1]
      //   sxn = s*maskScale[0]
      //   syn = s*maskScale[1]*imageWidth/imageHeight
      const s = 0.18782, x = -0.09803, y = 0.44314, ry = -0.04926;
      const aspect = 800 / 1000;

      final box = FaceBox.fromDetectState(kJocondeFace, settings, aspect: aspect);

      expect(box.xn, closeTo(x * 0.5 + 0.5 + s * -0.2 * math.sin(ry), 1e-12));
      expect(box.yn, closeTo(y * 0.5 + 0.5 + s * 0.1, 1e-12));
      expect(box.sxn, closeTo(s * 1.3, 1e-12));
      expect(box.syn, closeTo(s * 1.5 * aspect, 1e-12));
    });

    test('zoomFactor shrinks the user box relative to the painting box', () {
      final painting = FaceBox.fromDetectState(kJocondeFace, settings);
      final user = FaceBox.fromDetectState(kJocondeFace, settings,
          zoom: settings.zoomFactor);
      expect(user.sxn, lessThan(painting.sxn));
      expect(user.sxn, closeTo(painting.sxn / settings.zoomFactor, 1e-12));
    });

    test('topFlipped is the CSS-space top edge', () {
      // position_userCropCanvas(): topPx = H - H*positionFace[1], then minus
      // half the face height.
      const box = FaceBox(0.4, 0.6, 0.2, 0.3);
      expect(box.topFlipped, closeTo(1.0 - 0.6 - 0.15, 1e-12));
      final r = box.rectIn(200, 100);
      expect(r.left, closeTo(0.3 * 200, 1e-9));
      expect(r.top, closeTo(0.25 * 100, 1e-9));
      expect(r.width, closeTo(0.2 * 200, 1e-9));
      expect(r.height, closeTo(0.3 * 100, 1e-9));
    });
  });

  group('clampToBorder', () {
    test('leaves samples inside the 0.8 radius alone', () {
      final out = Float64List(2);
      clampToBorder(0.5, 0.5, out);
      expect(out[0], 0.5);
      expect(out[1], 0.5);

      // radius 0.5 from centre, well inside.
      clampToBorder(0.75, 0.5, out);
      expect(out[0], closeTo(0.75, 1e-12));
    });

    test('pulls outside samples back onto the circle', () {
      final out = Float64List(2);
      clampToBorder(0.02, 0.02, out);
      final r = math.sqrt(math.pow(2 * out[0] - 1, 2) + math.pow(2 * out[1] - 1, 2));
      expect(r, closeTo(0.8, 1e-9));
      // Direction is preserved: still in the same corner.
      expect(out[0], lessThan(0.5));
      expect(out[1], lessThan(0.5));
    });

    test('a corner sample is clamped, a centred one is not', () {
      final out = Float64List(2);
      clampToBorder(1.0, 1.0, out);
      expect(out[0], lessThan(1.0));
      clampToBorder(0.5, 0.9, out);
      expect(out[1], closeTo(0.9, 1e-12)); // radius 0.8 exactly, on the edge
    });
  });

  group('cutFaceHole', () {
    // A mid-grey painting so the luminance modulation is uniform and the
    // geometry is the only thing under test.
    final grey = texture(64, 64, (u, v) => const [0.5, 0.5, 0.5]);
    const box = FaceBox(0.5, 0.5, 0.5, 0.5);

    test('leaves everything outside the box fully opaque', () {
      final out = cutFaceHole(grey, box, settings);
      // Top-left corner is far outside the centred box.
      expect(pixel(out, 64, 2, 2)[3], closeTo(1.0, 1e-9));
      expect(pixel(out, 64, 2, 2)[0], closeTo(0.5, 0.01));
      expect(pixel(out, 64, 61, 61)[3], closeTo(1.0, 1e-9));
    });

    test('cuts a hole at the centre of the head', () {
      final out = cutFaceHole(grey, box, settings);
      expect(pixel(out, 64, 32, 32)[3], lessThan(0.05));
    });

    test('alpha rises from the centre of the head towards its edge', () {
      final out = cutFaceHole(grey, box, settings);
      // Along the middle row, walking left out of the hole. The probes start
      // at x=20 rather than at the very lip of the hole: alpha is squared on
      // the way out, so the outermost few pixels of the fade quantise to zero
      // in 8 bits — the demo's framebuffer does the same.
      final centre = pixel(out, 64, 32, 32)[3];
      final mid = pixel(out, 64, 20, 32)[3];
      final edge = pixel(out, 64, 17, 32)[3];
      expect(centre, lessThan(mid));
      expect(mid, lessThan(edge));
    });

    test('the head shape is narrower at the jaw than in the middle', () {
      final out = cutFaceHole(grey, box, settings);
      // The box spans rows 16..48. headJawY = 0.5 means the lower half of the
      // box is the jaw arc, i.e. rows 32..48 in this v-down buffer.
      int transparentRunOnRow(int y) {
        var n = 0;
        for (var x = 16; x < 48; x++) {
          if (pixel(out, 64, x, y)[3] < 0.5) n++;
        }
        return n;
      }

      final middle = transparentRunOnRow(30);
      final jaw = transparentRunOnRow(45);
      expect(jaw, lessThan(middle));
    });

    test('dark paint keeps more of the painting than lit paint', () {
      // Same geometry, two luminances: the smoothstep(0.1, 0.5, gray) term
      // pushes alpha towards pow(alpha, 0.5) when dark and pow(alpha, 1.5)
      // when light, so a dark painting is *more* opaque at a partial edge.
      final dark = texture(64, 64, (u, v) => const [0.05, 0.05, 0.05]);
      final light = texture(64, 64, (u, v) => const [0.9, 0.9, 0.9]);
      final aDark = pixel(cutFaceHole(dark, box, settings), 64, 22, 32)[3];
      final aLight = pixel(cutFaceHole(light, box, settings), 64, 22, 32)[3];
      expect(aDark, greaterThan(aLight));
    });

    test('output is premultiplied on alpha, not on the squared alpha', () {
      // The demo's blendFunc(SRC_ALPHA, ZERO) leaves colour*alpha in RGB and
      // alpha*alpha in A. Recovering alpha from A must reproduce the colour.
      // Probed where alpha is large enough that squaring it survives 8 bits.
      final out = cutFaceHole(grey, box, settings);
      for (final xy in const [[20, 32], [18, 32], [16, 32], [44, 34]]) {
        final p = pixel(out, 64, xy[0], xy[1]);
        final alpha = math.sqrt(p[3]);
        expect(p[0], closeTo(0.5 * alpha, 0.01),
            reason: 'at ${xy[0]},${xy[1]} a=$alpha');
      }
    });
  });

  group('hueSignature', () {
    test('cell 0 is the left of the box, matching the crop it is compared to',
        () {
      // Red on the left half of the box, blue on the right. The final shader
      // samples both signatures at the output pixel's own u, so painting cell
      // 0 must stay the painting's left — the demo's copyInvX exists only to
      // cancel its own mirrored sampling.
      final split = texture(64, 64, (u, v) => u < 0.5 ? const [1.0, 0.0, 0.0] : const [0.0, 0.0, 1.0]);
      const box = FaceBox(0.5, 0.5, 0.8, 0.8);
      final sig = hueSignature(split, box, settings);

      final left = Float64List(4);
      final right = Float64List(4);
      sig.sampleTopDown(0.125, 0.5, left);
      sig.sampleTopDown(0.875, 0.5, right);

      expect(left[0], greaterThan(0.8), reason: 'left cell should be red');
      expect(left[2], lessThan(0.2));
      expect(right[2], greaterThan(0.8), reason: 'right cell should be blue');
      expect(right[0], lessThan(0.2));
    });

    test('flipX swaps the palette across the face', () {
      final split = texture(64, 64, (u, v) => u < 0.5 ? const [1.0, 0.0, 0.0] : const [0.0, 0.0, 1.0]);
      const box = FaceBox(0.5, 0.5, 0.8, 0.8);
      final flipped = hueSignature(split, box, settings, flipX: true);
      final out = Float64List(4);
      flipped.sampleTopDown(0.125, 0.5, out);
      expect(out[2], greaterThan(0.8), reason: 'flipped, cell 0 is now blue');
    });

    test('row 0 is the top of the box', () {
      final gradient = texture(64, 64, (u, v) => [1.0 - v, 0.0, 0.0]);
      const box = FaceBox(0.5, 0.5, 0.6, 0.6);
      final sig = hueSignature(gradient, box, settings);
      final top = Float64List(4);
      final bottom = Float64List(4);
      sig.sampleTopDown(0.5, 0.125, top);
      sig.sampleTopDown(0.5, 0.875, bottom);
      // The gradient is brightest at v=0, which is the top of the image.
      expect(top[0], greaterThan(bottom[0]));
    });

    test('averages rather than point-samples', () {
      // Fine checkerboard: any single sample is 0 or 1, the average is 0.5.
      final check = texture(64, 64, (u, v) {
        final on = ((u * 64).floor() + (v * 64).floor()).isEven;
        return on ? const [1.0, 1.0, 1.0] : const [0.0, 0.0, 0.0];
      });
      const box = FaceBox(0.5, 0.5, 0.8, 0.8);
      final sig = hueSignature(check, box, settings);
      final out = Float64List(4);
      sig.sampleTopDown(0.5, 0.5, out);
      expect(out[0], closeTo(0.5, 0.15));
    });
  });

  group('hsv round trip', () {
    test('rgb -> hsv -> rgb is the identity', () {
      final hsv = Float64List(3);
      final rgb = Float64List(3);
      const cases = [
        [1.0, 0.0, 0.0],
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
        [0.5, 0.25, 0.75],
        [0.2, 0.2, 0.2],
        [0.0, 0.0, 0.0],
        [1.0, 1.0, 1.0],
        [0.9, 0.6, 0.1],
      ];
      for (final c in cases) {
        rgbToHsv(c[0], c[1], c[2], hsv);
        hsvToRgb(hsv[0], hsv[1], hsv[2], rgb);
        expect(rgb[0], closeTo(c[0], 1e-9), reason: '$c');
        expect(rgb[1], closeTo(c[1], 1e-9), reason: '$c');
        expect(rgb[2], closeTo(c[2], 1e-9), reason: '$c');
      }
    });

    test('hue is where it should be', () {
      final hsv = Float64List(3);
      rgbToHsv(1, 0, 0, hsv);
      expect(hsv[0], closeTo(0.0, 1e-9));
      rgbToHsv(0, 1, 0, hsv);
      expect(hsv[0], closeTo(1 / 3, 1e-9));
      rgbToHsv(0, 0, 1, hsv);
      expect(hsv[0], closeTo(2 / 3, 1e-9));
      rgbToHsv(0.5, 0.5, 0.5, hsv);
      expect(hsv[1], closeTo(0.0, 1e-9));
      expect(hsv[2], closeTo(0.5, 1e-9));
    });
  });

  group('FaceSwapCompositor', () {
    // A DetectState centred in frame, big enough that the box stays inside.
    const state = DetectState(
      detected: 1,
      x: 0,
      y: 0,
      s: 0.4,
      rx: 0,
      ry: 0,
      rz: 0,
    );

    ArtPainting fakePainting(Texture2D signature) => ArtPainting(
          image: dummyImage,
          box: FaceBox.fromDetectState(state, settings),
          hueSignature: signature,
          width: 100,
          height: 100,
        );

    test('returns null without colour', () {
      final mono = VideoLumaTexture(32, 32);
      final c = FaceSwapCompositor();
      expect(
        c.cropAndRecolour(
            video: mono, state: state, painting: fakePainting(_grey4)),
        isNull,
      );
    });

    test('returns null when tracking is lost', () {
      final v = video(32, 32, (u, vv) => const [0.5, 0.5, 0.5]);
      final c = FaceSwapCompositor();
      expect(
        c.cropAndRecolour(
            video: v, state: DetectState.lost, painting: fakePainting(_grey4)),
        isNull,
      );
    });

    test('crops the face box out of the frame', () {
      // Mark a small red square inside the box's upper-left quadrant; it must
      // land in the crop's upper-left quadrant.
      final box = FaceBox.fromDetectState(state, settings,
          zoom: settings.zoomFactor);
      // A point a quarter of the way in from the box's left, and a quarter
      // down from its top — in top-down video coordinates.
      final markU = box.xn - box.sxn * 0.25;
      final markV = 1.0 - (box.yn + box.syn * 0.25);

      final v = video(128, 128, (u, vv) {
        final hit = (u - markU).abs() < 0.02 && (vv - markV).abs() < 0.02;
        return hit ? const [1.0, 0.0, 0.0] : const [0.2, 0.2, 0.2];
      });

      final c = FaceSwapCompositor(settings: settings);
      final out = c.cropAndRecolour(
        video: v,
        state: state,
        painting: fakePainting(_grey4),
        mirror: false,
      )!;

      final n = settings.faceRenderSizePx;
      final p = pixel(out, n, (n * 0.25).round(), (n * 0.25).round());
      expect(p[0], greaterThan(p[1] + 0.2), reason: 'red should land here: $p');
    });

    test('mirror flips the crop horizontally', () {
      // Split by brightness, not by hue: the recolour rewrites hue outright
      // (a grey signature drags everything to hue 0), but value survives as a
      // clamped ratio, so dark stays dark.
      final v = video(128, 128,
          (u, vv) => u < 0.5 ? const [0.05, 0.05, 0.05] : const [0.9, 0.9, 0.9]);
      final c = FaceSwapCompositor(settings: settings);
      final n = settings.faceRenderSizePx;

      final straight = Uint8List.fromList(c.cropAndRecolour(
          video: v,
          state: state,
          painting: fakePainting(_grey4),
          mirror: false)!);
      final mirrored = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(_grey4), mirror: true)!;

      // The face box straddles the video's midline, so the crop's left edge
      // reads the video's dark half unmirrored and its light half mirrored.
      // (The recolour pulls both towards the grey signature's value, so these
      // are 0.15 and 0.40 rather than 0.05 and 0.9 — the ordering is the
      // claim, not the absolute levels.)
      final y = n ~/ 2;
      final dark = pixel(straight, n, 4, y)[0];
      final light = pixel(mirrored, n, 4, y)[0];
      expect(dark, lessThan(0.25));
      expect(light, greaterThan(0.3));
      expect(light, greaterThan(dark * 2));
    });

    test('identical signatures leave the face essentially untouched', () {
      // With src == dst the hue shift is zero and the saturation factor is 1;
      // only the deliberate 0.8 on value applies.
      final v = video(128, 128, (u, vv) => const [0.6, 0.4, 0.3]);
      final c = FaceSwapCompositor(settings: settings);
      final flat = texture(4, 4, (u, vv) => const [0.6, 0.4, 0.3]);
      final out = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(flat))!;

      final n = settings.faceRenderSizePx;
      final p = pixel(out, n, n ~/ 2, n ~/ 2);
      // Hue and saturation preserved, value scaled by 0.8.
      final hsv = Float64List(3);
      rgbToHsv(p[0], p[1], p[2], hsv);
      final want = Float64List(3);
      rgbToHsv(0.6, 0.4, 0.3, want);
      expect(hsv[0], closeTo(want[0], 0.02));
      expect(hsv[1], closeTo(want[1], 0.02));
      expect(hsv[2], closeTo(want[2] * 0.8, 0.02));
    });

    test('shifts the face hue towards the painting', () {
      // A green user in front of a red painting comes out redder.
      final v = video(128, 128, (u, vv) => const [0.2, 0.7, 0.2]);
      final red = texture(4, 4, (u, vv) => const [0.7, 0.2, 0.2]);
      final c = FaceSwapCompositor(settings: settings);
      final out = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(red))!;

      final n = settings.faceRenderSizePx;
      final p = pixel(out, n, n ~/ 2, n ~/ 2);
      expect(p[0], greaterThan(p[1]),
          reason: 'green user + red painting should read red: $p');
    });

    test('the value factor is clamped, so a black painting cannot black out '
        'the face', () {
      final v = video(128, 128, (u, vv) => const [0.6, 0.6, 0.6]);
      final black = texture(4, 4, (u, vv) => const [0.0, 0.0, 0.0]);
      final c = FaceSwapCompositor(settings: settings);
      final out = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(black))!;

      final n = settings.faceRenderSizePx;
      final p = pixel(out, n, n ~/ 2, n ~/ 2);
      // factorSV is clamped to 0.3 at the bottom: 0.6 * 0.3 = 0.18.
      expect(p[0], closeTo(0.6 * 0.3, 0.02));
    });

    test('records the user signature it built', () {
      final v = video(128, 128, (u, vv) => const [0.1, 0.8, 0.4]);
      final c = FaceSwapCompositor(settings: settings);
      c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(_grey4));
      final sig = c.userSignature!;
      expect(sig.width, settings.hueTextureSizePx);
      final out = Float64List(4);
      sig.sampleTopDown(0.5, 0.5, out);
      expect(out[0], closeTo(0.1, 0.02));
      expect(out[1], closeTo(0.8, 0.02));
      expect(out[2], closeTo(0.4, 0.02));
    });

    test('reuses one buffer across frames', () {
      final v = video(64, 64, (u, vv) => const [0.5, 0.5, 0.5]);
      final c = FaceSwapCompositor(settings: settings);
      final a = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(_grey4));
      final b = c.cropAndRecolour(
          video: v, state: state, painting: fakePainting(_grey4));
      expect(identical(a, b), isTrue);
    });
  });

  group('ArtPaintingController.locateFace', () {
    test('returns lost for a painting with no detected face', () {
      expect(ArtPaintingController.locateFace(null, const Size(800, 1000)).detected,
          0);
      expect(
          ArtPaintingController.locateFace(
                  const <Offset>[], const Size(800, 1000))
              .detected,
          0);
    });

    test('a centred synthetic face solves to roughly the centre of the image',
        () {
      // Feed the canonical face straight back in, projected orthographically
      // into the middle of a square image: x and y should come out near zero.
      final lm = _canonicalAsLandmarks(
          centre: const Offset(0.5, 0.5), scale: 0.35);
      final state =
          ArtPaintingController.locateFace(lm, const Size(512, 512));
      expect(state.detected, greaterThan(0));
      expect(state.x.abs(), lessThan(0.15));
      expect(state.y.abs(), lessThan(0.25));
      expect(state.s, greaterThan(0.0));
    });

    test('moving the face left moves the solved x left', () {
      final left = ArtPaintingController.locateFace(
          _canonicalAsLandmarks(centre: const Offset(0.3, 0.5), scale: 0.35),
          const Size(512, 512));
      final right = ArtPaintingController.locateFace(
          _canonicalAsLandmarks(centre: const Offset(0.7, 0.5), scale: 0.35),
          const Size(512, 512));
      expect(left.x, lessThan(right.x));
    });

    test('a bigger face solves to a bigger s, which widens the box', () {
      final small = ArtPaintingController.locateFace(
          _canonicalAsLandmarks(centre: const Offset(0.5, 0.5), scale: 0.2),
          const Size(512, 512));
      final big = ArtPaintingController.locateFace(
          _canonicalAsLandmarks(centre: const Offset(0.5, 0.5), scale: 0.4),
          const Size(512, 512));
      expect(big.s, greaterThan(small.s));
      expect(FaceBox.fromDetectState(big, settings).sxn,
          greaterThan(FaceBox.fromDetectState(small, settings).sxn));
    });
  });

  group('kArtPaintings', () {
    test('lists the ten demo images', () {
      expect(kArtPaintings.length, 10);
      expect(kArtPaintings.first, 'artPainting/Joconde.jpg');
      expect(kArtPaintings.toSet().length, 10);
    });
  });
}

/// The canonical face landmarks, projected flat into an image — enough of a
/// face for the pose solver to work on, without needing a real detector.
List<Offset> _canonicalAsLandmarks({
  required Offset centre,
  required double scale,
}) {
  // kCanonicalFace is keyed by landmark index in millimetres. Drop z and map
  // the x/y extent onto `scale` of the image.
  final entries = kCanonicalFace.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  var maxIndex = 0;
  for (final e in entries) {
    if (e.key > maxIndex) maxIndex = e.key;
  }

  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final e in entries) {
    minX = math.min(minX, e.value.x);
    maxX = math.max(maxX, e.value.x);
    minY = math.min(minY, e.value.y);
    maxY = math.max(maxY, e.value.y);
  }
  final span = math.max(maxX - minX, maxY - minY);
  final k = scale / span;

  final out = List<Offset>.filled(maxIndex + 1, centre);
  for (final e in entries) {
    // Canonical y is up; image y is down.
    out[e.key] = Offset(
      centre.dx + e.value.x * k,
      centre.dy - e.value.y * k,
    );
  }
  return out;
}

final Texture2D _grey4 =
    Texture2D(4, 4, Uint8List.fromList(List<int>.filled(4 * 4 * 4, 128)));
