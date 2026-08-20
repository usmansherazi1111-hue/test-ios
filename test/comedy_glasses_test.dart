// The CSS3D comedy-glasses port.
//
// This path never touches the rasteriser, so there is no framebuffer to
// inspect — the whole output is one matrix. That makes it very easy to be
// subtly wrong and impossible to notice without arithmetic, so the matrix is
// checked against values worked out by hand from the demo's own constants.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

/// A face dead centre, filling 30% of the frame width, looking straight ahead.
DetectState centred({
  double s = 0.3,
  double x = 0,
  double y = 0,
  double rx = 0,
  double ry = 0,
  double rz = 0,
  double mouth = 0,
}) =>
    DetectState(
      detected: 1,
      x: x,
      y: y,
      s: s,
      rx: rx,
      ry: ry,
      rz: rz,
      expressions: [mouth],
    );

void main() {
  group('perspective', () {
    test('uses the whole FOV, not half of it', () {
      // perspectivePx = round(sqrt(w2^2 + h2^2) / tan(fov * PI / 180)).
      // For a 600x600 element at fov 40: sqrt(300^2+300^2)/tan(40 deg).
      final placer = Css3dPlacer();
      final pose = placer.place(centred(), 600, 600);

      final expected =
          (math.sqrt(300.0 * 300 + 300 * 300) / math.tan(40 * math.pi / 180))
              .roundToDouble();
      expect(pose.perspective, expected);
      // Sanity: halving the FOV would give a very different number, so this
      // pins which of the two the demo actually uses.
      final halved =
          (math.sqrt(300.0 * 300 + 300 * 300) / math.tan(20 * math.pi / 180))
              .roundToDouble();
      expect(pose.perspective, isNot(closeTo(halved, 1)));
    });

    test('lands in the matrix as -1/P at row 3, column 2', () {
      final placer = Css3dPlacer();
      final pose = placer.place(centred(), 600, 600);
      // Column-major: index 11 is row 3, column 2.
      expect(pose.matrix.m[11], closeTo(-1 / pose.perspective, 1e-12));
    });
  });

  group('placement', () {
    test('a centred face puts the element on the centre line', () {
      final pose = Css3dPlacer().place(centred(), 600, 600);
      expect(pose.visible, isTrue);
      // x is 0 in, so 0 out; y carries the pivot and position offsets.
      expect(pose.matrix.m[12], closeTo(0, 1e-9));
      expect(pose.matrix.m[14], lessThan(0), reason: 'the element sits behind');
    });

    test('the element ends up about 1.26x the head width', () {
      // This is the whole reason the demo works: the div is *canvas-sized* and
      // scaled 1.3x, which sounds enormous — but it sits far enough back that
      // the perspective divide brings it down to roughly head size.
      const side = 600.0;
      const s = 0.3; // head fills 30% of the frame
      final pose = Css3dPlacer().place(centred(s: s), side, side);

      final z = pose.matrix.m[14];
      final apparent = pose.perspective / (pose.perspective - z);
      final onScreen = side * 1.3 * apparent; // div size * scale * foreshorten

      const headPx = s * side;
      expect(onScreen / headPx, closeTo(1.26, 0.15),
          reason: 'comedy glasses are a bit wider than the face');
    });

    test('a bigger face moves the element closer', () {
      final placer = Css3dPlacer();
      final far = placer.place(centred(s: 0.2), 600, 600).matrix.m[14];
      final near = placer.place(centred(s: 0.5), 600, 600).matrix.m[14];
      expect(near, greaterThan(far),
          reason: 'z is negative going away, so a nearer head is less negative');
    });

    test('mirroring flips x and yaw but not pitch or roll', () {
      const mirrored = Css3dSettings();
      const plain = Css3dSettings(mirror: false);
      final state = centred(x: 0.5, ry: 0.4, rx: 0.3, rz: 0.2);

      final a = Css3dPlacer(settings: mirrored).place(state, 600, 600);
      final b = Css3dPlacer(settings: plain).place(state, 600, 600);

      // Horizontal placement swaps sides. Not an exact negation: flipping the
      // yaw also rotates the pivot offset, which feeds back into the position —
      // so the sign is the claim, not the magnitude.
      expect(a.matrix.m[12], lessThan(0));
      expect(b.matrix.m[12], greaterThan(0));
      expect(a.matrix.m[12].abs(),
          closeTo(b.matrix.m[12].abs(), b.matrix.m[12].abs() * 0.05));

      // Depth is essentially untouched by a horizontal mirror.
      expect(a.matrix.m[14], closeTo(b.matrix.m[14], b.matrix.m[14].abs() * 0.05));
    });

    test('Y is negated — CSS and Flutter both count down the screen', () {
      // A face *above* centre (positive y in tracker NDC, which counts up)
      // must move the element *up* the screen, i.e. towards negative Y in
      // widget space.
      final placer = Css3dPlacer();
      final up = placer.place(centred(y: 0.5), 600, 600).matrix.m[13];
      final down = placer.place(centred(y: -0.5), 600, 600).matrix.m[13];
      expect(up, lessThan(down));
    });
  });

  group('detection latch', () {
    test('hysteresis keeps a borderline face from flickering', () {
      final placer = Css3dPlacer();
      // Threshold 0.75, hysteresis 0.05 — so it turns on above 0.80 and off
      // below 0.70, and does nothing in between.
      expect(placer.place(centred(), 600, 600).visible, isTrue);

      // Drop into the dead band: still visible.
      expect(
          placer
              .place(
                  const DetectState(
                      detected: 0.72, x: 0, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
                  600,
                  600)
              .visible,
          isTrue);

      // Below the lower edge: lost.
      expect(
          placer
              .place(
                  const DetectState(
                      detected: 0.6, x: 0, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
                  600,
                  600)
              .visible,
          isFalse);

      // Back into the dead band from below: still lost.
      expect(
          placer
              .place(
                  const DetectState(
                      detected: 0.78, x: 0, y: 0, s: 0.3, rx: 0, ry: 0, rz: 0),
                  600,
                  600)
              .visible,
          isFalse);
    });

    test('a lost face reports hidden rather than a stale matrix', () {
      final placer = Css3dPlacer();
      placer.place(centred(), 600, 600);
      final lost = placer.place(DetectState.lost, 600, 600);
      expect(lost.visible, isFalse);
    });
  });

  group('mouth latch', () {
    test('opens above 0.55 and closes below 0.45', () {
      final placer = Css3dPlacer();
      expect(placer.place(centred(mouth: 0.0), 600, 600).isMouthOpen, isFalse);

      // Inside the dead band from below — no change.
      expect(placer.place(centred(mouth: 0.52), 600, 600).isMouthOpen, isFalse);
      // Past the upper edge — opens.
      expect(placer.place(centred(mouth: 0.6), 600, 600).isMouthOpen, isTrue);
      // Back into the dead band — stays open.
      expect(placer.place(centred(mouth: 0.48), 600, 600).isMouthOpen, isTrue);
      // Past the lower edge — closes.
      expect(placer.place(centred(mouth: 0.4), 600, 600).isMouthOpen, isFalse);
    });

    test('reset clears both latches', () {
      final placer = Css3dPlacer();
      placer.place(centred(mouth: 1.0), 600, 600);
      expect(placer.isDetected, isTrue);
      expect(placer.isMouthOpen, isTrue);

      placer.reset();
      expect(placer.isDetected, isFalse);
      expect(placer.isMouthOpen, isFalse);
    });
  });

  group('controller', () {
    testWidgets('drives a transform from landmarks', (tester) async {
      final controller = JeelizCss3dController();
      addTearDown(controller.dispose);

      expect(controller.isFaceDetected, isFalse);

      // Synthesise a face by projecting the canonical head, the same trick the
      // pose-pipeline test uses.
      const imgW = 720.0, imgH = 1280.0;
      final maxIndex = kCanonicalFace.keys.reduce((a, b) => a > b ? a : b);
      final lm = List<Offset>.filled(maxIndex + 1, Offset.zero);
      var sum = Vec3.zero;
      for (final p in kCanonicalFace.values) {
        sum = sum + p;
      }
      final centroid = sum * (1.0 / kCanonicalFace.length);
      for (final e in kCanonicalFace.entries) {
        final d = e.value - centroid;
        lm[e.key] = Offset(
          (d.x * 3.0 + imgW / 2) / imgW,
          (-d.y * 3.0 + imgH / 2) / imgH,
        );
      }

      controller.feedLandmarks(
          lm, const Size(imgW, imgH), const Size(400, 800));

      expect(controller.lastState.detected, 1.0);
      expect(controller.isFaceDetected, isTrue);
      expect(controller.pose.visible, isTrue);
      expect(controller.pose.perspective, greaterThan(0));

      // And losing the face hides it, after the adapter's hold window.
      for (var i = 0; i < 12; i++) {
        controller.feedLandmarks(
            null, const Size(imgW, imgH), const Size(400, 800));
      }
      expect(controller.pose.visible, isFalse);
    });

    testWidgets('the overlay renders its child only while tracked',
        (tester) async {
      final controller = JeelizCss3dController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: JeelizCss3dOverlay(
            controller: controller,
            child: const SizedBox(key: ValueKey('glasses')),
          ),
        ),
      );

      // No face yet, so nothing to show.
      expect(find.byKey(const ValueKey('glasses')), findsNothing);
    });
  });
}
