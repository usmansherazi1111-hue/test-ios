// Renders the real tiger assets.
//
// The pieces most likely to be silently wrong here are the ones with no
// obvious visual tell until you are holding a phone: the four material groups
// lining up with the right index ranges, the jaw deformation only touching the
// lower jaw, and the video term — which, if it goes missing, turns the eye
// region black rather than see-through, because that region is *painted*
// video, not transparency.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TigerFilter filter;
  late JeelizFaceFilterHelper helper;
  late PerspectiveCamera camera;
  late Framebuffer fb;
  late SoftwareRenderer renderer;

  setUp(() async {
    filter = TigerFilter();
    await filter.load();

    helper = JeelizFaceFilterHelper();
    camera = helper.createCamera();
    renderer = SoftwareRenderer();
    fb = Framebuffer(270, 480);
    filter.attach(helper);
    helper.updateCamera(camera,
        canvasWidth: 270, canvasHeight: 480, videoWidth: 720, videoHeight: 1280);
  });

  int drawnPixels() {
    var n = 0;
    for (var i = 3; i < fb.color.length; i += 4) {
      if (fb.color[i] > 0) n++;
    }
    return n;
  }

  DetectState head({double mouth = 0, double ry = 0}) => DetectState(
        detected: 1,
        x: 0,
        y: 0,
        s: 0.35,
        rx: 0,
        ry: ry,
        rz: 0,
        expressions: [mouth],
      );

  /// A synthetic camera frame: a horizontal luma ramp, so a wrong lookup
  /// shows up as the wrong brightness rather than as nothing at all.
  VideoLumaTexture rampVideo() {
    final sampler = VideoLumaSampler(maxDimension: 64);
    const w = 72, h = 128;
    final plane = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        plane[y * w + x] = (255 * x ~/ (w - 1));
      }
    }
    return sampler.fromLumaPlane(plane, w, h, rowStride: w);
  }

  void draw(DetectState s, {double dt = 1 / 30}) {
    helper.update([s], camera);
    filter.update(s, dt);
    fb.clear();
    if (helper.isDetected) renderer.render(helper.scene, camera, fb);
  }

  test('TigerHead.json carries UVs, normals and four material groups', () async {
    final geom = decodeBufferGeometry(
        await loadJeelizAssetString('tiger/TigerHead.json'));

    expect(geom.vertexCount, 1165);
    expect(geom.uvs, isNotNull);
    expect(geom.uvs!.length, 2330);
    expect(geom.hasSuppliedNormals, isTrue,
        reason: 'the export ships normals; re-smoothing would soften creases');

    expect(geom.groups.length, 4);
    expect(geom.groups.map((g) => g.materialIndex).toList(), [0, 1, 2, 3]);
    expect(geom.groups.map((g) => g.count).toList(), [90, 2640, 3348, 120]);
    // Groups must tile the index buffer exactly, or a slice goes undrawn.
    var cursor = 0;
    for (final g in geom.groups) {
      expect(g.start, cursor);
      cursor += g.count;
    }
    expect(cursor, geom.indices.length);
  });

  test('a detected face draws the tiger', () {
    filter.setVideo(rampVideo());
    draw(head());

    final painted = drawnPixels();
    expect(painted, greaterThan(3000), reason: 'the head covers real area');
    expect(renderer.stats.fragments, greaterThan(0));

    // The mask is opaque by construction, so wherever it drew, alpha is full.
    var opaque = 0;
    for (var i = 3; i < fb.color.length; i += 4) {
      if (fb.color[i] == 255) opaque++;
    }
    expect(opaque, greaterThan(painted ~/ 2));
  });

  test('the eye region paints video, not black', () {
    // With a bright video the see-through region must be bright; with a dark
    // one it must be dark. That is the whole point of the video term, and the
    // failure mode without it (black sockets) is exactly what this catches.
    filter.setVideo(rampVideo());
    draw(head());
    var brightSum = 0;
    for (var i = 0; i < fb.color.length; i += 4) {
      if (fb.color[i + 3] > 0) brightSum += fb.color[i];
    }

    filter.setVideo(null);
    draw(head());
    var darkSum = 0;
    for (var i = 0; i < fb.color.length; i += 4) {
      if (fb.color[i + 3] > 0) darkSum += fb.color[i];
    }

    expect(brightSum, greaterThan(darkSum),
        reason: 'video luma must reach the framebuffer');
  });

  test('opening the mouth only moves the lower jaw', () {
    final mat = TigerMaskMaterial(map: Texture2D.solid(255, 255, 255));
    final out = Float64List(3);

    // Upper face: position.y + position.z*0.2 > 0 -> untouched.
    mat.mouthOpening = 1.0;
    mat.deformVertex(0.1, 0.4, 0.0, out);
    expect(out[1], closeTo(0.4, 1e-12));
    expect(out[2], closeTo(0.0, 1e-12));

    // Lower jaw: rotates in the YZ plane, preserving its distance from the
    // hinge.
    const y = -0.2, z = 0.3;
    mat.deformVertex(0.1, y, z, out);
    expect(out[0], closeTo(0.1, 1e-12), reason: 'X is never touched');
    expect(out[1] * out[1] + out[2] * out[2],
        closeTo(y * y + z * z, 1e-9),
        reason: 'a rotation preserves length');
    expect(out[1], isNot(closeTo(y, 1e-6)));

    // Closed mouth is the identity.
    mat.mouthOpening = 0.0;
    mat.deformVertex(0.1, y, z, out);
    expect(out[1], closeTo(y, 1e-12));
    expect(out[2], closeTo(z, 1e-12));
  });

  test('particles fire only when the mouth is wide, and expire', () {
    filter.setVideo(rampVideo());

    draw(head(mouth: 0.0));
    expect(_visibleSprites(helper), 0, reason: 'closed mouth fires nothing');

    // main.js gates on mouthOpening > 0.5.
    draw(head(mouth: 0.4));
    expect(_visibleSprites(helper), 0, reason: 'below threshold fires nothing');

    for (var i = 0; i < 10; i++) {
      draw(head(mouth: 1.0));
    }
    final flying = _visibleSprites(helper);
    expect(flying, greaterThan(0), reason: 'wide mouth sprays particles');

    // Each particle lives ~2s; run well past that with the mouth shut.
    for (var i = 0; i < 100; i++) {
      draw(head(mouth: 0.0), dt: 0.05);
    }
    expect(_visibleSprites(helper), 0, reason: 'particles must expire');
  });

  test('an undetected face draws nothing', () {
    filter.setVideo(rampVideo());
    draw(DetectState.lost);
    expect(helper.isDetected, isFalse);
    expect(drawnPixels(), 0);
  });

  test('renders within a frame budget', () {
    filter.setVideo(rampVideo());
    draw(head(mouth: 1.0)); // warm up, and get particles in flight

    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      draw(head(mouth: 1.0));
    }
    sw.stop();
    final perFrameMs = sw.elapsedMilliseconds / 10;
    expect(perFrameMs, lessThan(250), reason: '${perFrameMs}ms per frame');
  });
}

int _visibleSprites(JeelizFaceFilterHelper helper) {
  var n = 0;
  helper.scene.traverseVisible((o) {
    if (o is Sprite) n++;
  });
  return n;
}
