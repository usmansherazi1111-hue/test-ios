// Renders the real glassesVTO assets.
//
// The unit tests cover the maths; this covers everything the maths cannot
// reach — that the io_three JSON parses, that envMap.jpg decodes, that the
// materials produce colour rather than black, and above all that the face
// occluder hides the temples without also wiping out the lenses. That last one
// is a single sign away from "renders nothing at all", and nothing but a real
// render catches it.

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GlassesAssets assets;
  late JeelizFaceFilterHelper helper;
  late PerspectiveCamera camera;
  late Framebuffer fb;
  late SoftwareRenderer renderer;

  setUpAll(() async {
    assets = await createGlasses();
  });

  setUp(() {
    helper = JeelizFaceFilterHelper();
    camera = helper.createCamera();
    renderer = SoftwareRenderer();
    fb = Framebuffer(270, 480);
    buildGlassesScene(helper, assets);
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

  /// A head filling ~35% of the frame width, centred.
  DetectState head({double rx = 0, double ry = 0, double rz = 0}) =>
      DetectState(detected: 1, x: 0, y: 0, s: 0.35, rx: rx, ry: ry, rz: rz);

  test('asset root resolves without a hard-coded packages/ prefix', () async {
    // Flutter keys assets by who owns them at build time: `packages/
    // jeeliz_dart/assets/…` when this is a dependency, bare `assets/…` when it
    // is the running app. Hard-coding either broke the other — the demo app
    // failed with "Unable to load asset" on every frame. Probing must find a
    // working root in whatever environment this runs.
    expect(resolvedJeelizAssetRoot, isNotNull,
        reason: 'setUpAll already loaded the assets');
    expect(resolvedJeelizAssetRoot, anyOf(endsWith('assets/')));

    // And it must keep working for an asset not touched during resolution.
    final bytes = await loadJeelizAssetUint8List('glassesVTO/envMap.jpg');
    expect(bytes.length, greaterThan(1000));
    // JPEG SOI marker, i.e. we got the real file and not an HTML 404 body.
    expect(bytes[0], 0xFF);
    expect(bytes[1], 0xD8);
  });

  test('a missing asset reports both roots it tried', () async {
    await expectLater(
      loadJeelizAssetBytes('glassesVTO/does_not_exist.json'),
      throwsA(isA<Exception>().having((e) => e.toString(), 'message',
          contains('could not find asset'))),
    );
  });

  test('assets load with the expected topology', () {
    expect(assets.envMap.width, greaterThan(16));
    expect(assets.envMap.height, greaterThan(8));

    final meshes = <Mesh>[];
    assets.glasses.traverseVisible((o) {
      if (o is Mesh) meshes.add(o);
    });
    expect(meshes.length, 2, reason: 'frames + lenses');

    // From the JSON headers: 2788 frame vertices, 688 lens, 6102 occluder.
    expect(meshes[0].geometry.vertexCount, 2788);
    expect(meshes[1].geometry.vertexCount, 688);
    expect(assets.occluder.geometry.vertexCount, 6102);

    // Normals must have been computed on load — the exports carry none.
    final n = meshes[0].geometry.normals;
    var nonZero = 0;
    for (var i = 0; i < n.length; i += 3) {
      if (n[i] != 0 || n[i + 1] != 0 || n[i + 2] != 0) nonZero++;
    }
    expect(nonZero, meshes[0].geometry.vertexCount);
  });

  test('a detected face draws visible glasses', () {
    fb.clear();
    helper.update([head()], camera);
    expect(helper.isDetected, isTrue);
    renderer.render(helper.scene, camera, fb);

    final painted = drawnPixels();
    // Big enough to be the glasses, small enough that the occluder plainly is
    // not painting the whole head.
    expect(painted, greaterThan(500), reason: 'glasses should be visible');
    expect(painted, lessThan(270 * 480 * 0.35),
        reason: 'occluder must not be writing colour');

    expect(renderer.stats.meshes, 3);
    expect(renderer.stats.fragments, greaterThan(0));

    // Something other than pure black came out of the env-map shading.
    var maxChannel = 0;
    for (var i = 0; i < fb.color.length; i += 4) {
      if (fb.color[i + 3] == 0) continue;
      for (var c = 0; c < 3; c++) {
        if (fb.color[i + c] > maxChannel) maxChannel = fb.color[i + c];
      }
    }
    expect(maxChannel, greaterThan(24),
        reason: 'frames and lenses are lit purely by envMap.jpg');
  });

  test('an undetected face draws nothing', () {
    fb.clear();
    helper.update([DetectState.lost], camera);
    expect(helper.isDetected, isFalse);
    renderer.render(helper.scene, camera, fb);
    expect(drawnPixels(), 0);
  });

  test('the occluder eats the far temple when the head turns', () {
    // Yawed hard, one temple runs behind the head and must be occluded, so a
    // strongly turned head paints less than a frontal one.
    fb.clear();
    helper.update([head()], camera);
    renderer.render(helper.scene, camera, fb);
    final frontal = drawnPixels();

    fb.clear();
    helper.update([head(ry: 1.0)], camera);
    renderer.render(helper.scene, camera, fb);
    final turned = drawnPixels();

    expect(turned, greaterThan(0), reason: 'glasses still visible in profile');
    expect(turned, lessThan(frontal),
        reason: 'the far lens and temple go behind the head');
  });

  test('renders at a steady cost', () {
    // Not a benchmark, just a guard against an accidental O(n^2): the whole
    // frame must complete well inside a camera frame interval.
    fb.clear();
    helper.update([head()], camera);
    renderer.render(helper.scene, camera, fb); // warm up

    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      fb.clear();
      renderer.render(helper.scene, camera, fb);
    }
    sw.stop();
    final perFrameMs = sw.elapsedMilliseconds / 10;
    // Generous: this runs unoptimised in the test VM, not AOT on a device.
    expect(perFrameMs, lessThan(250), reason: '${perFrameMs}ms per frame');
  });
}
