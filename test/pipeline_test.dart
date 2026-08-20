// End-to-end checks on the parts that have no visual tell when they go wrong.
//
// The important one is `landmarks -> DetectState -> update_poses -> projection`
// closing the loop: build landmarks by projecting the canonical head with a
// known pose, push them through the real pipeline, and confirm the head lands
// back exactly where it started. Every constant in the tracking adapter is
// under test at once, which is the only practical way to catch a sign error in
// the Euler extraction or the pivot inversion short of pointing a phone at a
// face.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

const double _imgW = 720;
const double _imgH = 1280;

/// Canonical centroid — the point the POS solver anchors on.
final Vec3 _centroid = () {
  var s = Vec3.zero;
  for (final p in kCanonicalFace.values) {
    s = s + p;
  }
  return s * (1.0 / kCanonicalFace.length);
}();

/// Builds landmarks by projecting [kCanonicalFace] orthographically, which is
/// exactly the model the POS solver assumes.
List<Offset> synthesiseLandmarks({
  required double rx,
  required double ry,
  required double rz,
  required double scale, // pixels per canonical mm
  required Offset centroidPx,
}) {
  final r = Mat4.rotationFromEuler(Euler(rx, ry, rz, EulerOrder.zyx));
  // three rows -> POS rows: image x = three x, image y (down) = -three y.
  final m = r.m;
  Vec3 row(int i) => Vec3(m[i], m[4 + i], m[8 + i]); // column-major read

  final r0 = row(0);
  final r1 = -row(1);

  final maxIndex =
      kCanonicalFace.keys.reduce((a, b) => a > b ? a : b);
  final out = List<Offset>.filled(maxIndex + 1, const Offset(0, 0));

  for (final e in kCanonicalFace.entries) {
    final d = e.value - _centroid;
    final px = r0.dot(d) * scale + centroidPx.dx;
    final py = r1.dot(d) * scale + centroidPx.dy;
    out[e.key] = Offset(px / _imgW, py / _imgH);
  }
  return out;
}

/// Projects a point expressed in [node]'s local space to source-image pixels.
Offset projectThroughScene(
    Object3D node, Vec3 local, PerspectiveCamera camera) {
  final world = node.matrixWorld.transformPoint(local);
  final clip =
      (camera.projectionMatrix * camera.matrixWorldInverse).transformToClip(world);
  final iw = 1.0 / clip[3];
  return Offset((clip[0] * iw * 0.5 + 0.5) * _imgW,
      (0.5 - clip[1] * iw * 0.5) * _imgH);
}

/// Stands the real pipeline up over synthetic landmarks.
({JeelizFaceFilterHelper helper, PerspectiveCamera camera, Object3D glasses, DetectState state})
    runPipeline({
  double rx = 0,
  double ry = 0,
  double rz = 0,
  double scale = 3.0,
  Offset centroidPx = const Offset(_imgW / 2, _imgH / 2),
}) {
  final helper = JeelizFaceFilterHelper();
  final camera = helper.createCamera();
  final adapter = LandmarkDetectStateAdapter(smoothing: 1.0);

  // Same hierarchy main.js builds, without needing the asset bundle.
  final glasses = Object3D(name: 'glasses')..position = const Vec3(0, 0.07, 0.4);
  glasses.scaleUniform(0.006);
  helper.faceObject.add(glasses);

  helper.updateCamera(camera,
      canvasWidth: _imgW,
      canvasHeight: _imgH,
      videoWidth: _imgW,
      videoHeight: _imgH);

  final lm = synthesiseLandmarks(
      rx: rx, ry: ry, rz: rz, scale: scale, centroidPx: centroidPx);
  final state = adapter.convert(lm, const Size(_imgW, _imgH), camera);

  helper.update([state], camera);
  helper.scene.updateMatrixWorld();
  camera.updateProjectionMatrix();

  return (helper: helper, camera: camera, glasses: glasses, state: state);
}

void main() {
  group('Mat4', () {
    test('ZYX Euler matches three.js makeRotationFromEuler', () {
      // three.js r112, new THREE.Matrix4().makeRotationFromEuler(
      //   new THREE.Euler(0.3, -0.4, 0.5, 'ZYX')).elements
      final m = Mat4.rotationFromEuler(const Euler(0.3, -0.4, 0.5, EulerOrder.zyx)).m;
      const a = 0.3, b = -0.4, c = 0.5;
      final ca = math.cos(a), sa = math.sin(a);
      final cb = math.cos(b), sb = math.sin(b);
      final cc = math.cos(c), sc = math.sin(c);

      // R = Rz · Ry · Rx, computed independently here.
      final expected = <double>[
        cb * cc, sa * sb * cc - ca * sc, ca * sb * cc + sa * sc, //
        cb * sc, sa * sb * sc + ca * cc, ca * sb * sc - sa * cc, //
        -sb, sa * cb, ca * cb,
      ];
      for (var row = 0; row < 3; row++) {
        for (var col = 0; col < 3; col++) {
          expect(m[col * 4 + row], closeTo(expected[row * 3 + col], 1e-12),
              reason: 'element ($row,$col)');
        }
      }
    });

    test('perspective matrix matches three.js makePerspective', () {
      final cam = PerspectiveCamera(fov: 62.2, aspect: 0.5625, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final m = cam.projectionMatrix.m;
      final top = 0.1 * math.tan(62.2 * math.pi / 360);
      final right = 0.5625 * top;
      expect(m[0], closeTo(0.1 / right, 1e-12));
      expect(m[5], closeTo(0.1 / top, 1e-12));
      expect(m[11], -1.0);
      expect(m[10], closeTo(-(100 + 0.1) / (100 - 0.1), 1e-12));
    });

    test('inverse round-trips', () {
      final m = Mat4.compose(const Vec3(1, -2, 3),
          const Euler(0.2, 0.3, -0.4, EulerOrder.zyx), const Vec3(2, 2, 2));
      final inv = m.inverted!;
      const p = Vec3(0.4, -1.2, 5.0);
      final rt = inv.transformPoint(m.transformPoint(p));
      expect(rt.x, closeTo(p.x, 1e-9));
      expect(rt.y, closeTo(p.y, 1e-9));
      expect(rt.z, closeTo(p.z, 1e-9));
    });
  });

  group('tracking adapter closes the loop', () {
    for (final pose in [
      (name: 'frontal', rx: 0.0, ry: 0.0, rz: 0.0),
      (name: 'yaw right', rx: 0.0, ry: 0.5, rz: 0.0),
      (name: 'yaw left', rx: 0.0, ry: -0.5, rz: 0.0),
      (name: 'pitch up', rx: -0.35, ry: 0.0, rz: 0.0),
      (name: 'roll', rx: 0.0, ry: 0.0, rz: 0.4),
      (name: 'combined', rx: 0.22, ry: -0.33, rz: 0.18),
    ]) {
      test('${pose.name}: recovers the head rotation', () {
        final r = runPipeline(rx: pose.rx, ry: pose.ry, rz: pose.rz);
        expect(r.state.detected, 1.0);
        expect(r.state.rx, closeTo(pose.rx, 2e-3), reason: 'rx');
        expect(r.state.ry, closeTo(pose.ry, 2e-3), reason: 'ry');
        expect(r.state.rz, closeTo(pose.rz, 2e-3), reason: 'rz');
      });

      test('${pose.name}: head centroid reprojects onto its landmarks', () {
        const centroidPx = Offset(_imgW * 0.42, _imgH * 0.38);
        final r = runPipeline(
            rx: pose.rx, ry: pose.ry, rz: pose.rz, centroidPx: centroidPx);

        // The centroid, expressed in the face object's local (cube) space.
        const cal = JeelizCubeCalibration();
        final local = (_centroid - cal.origin) * (1.0 / cal.unitMm);
        final got = projectThroughScene(r.helper.faceObject, local, r.camera);

        expect(got.dx, closeTo(centroidPx.dx, 0.5), reason: 'x');
        expect(got.dy, closeTo(centroidPx.dy, 0.5), reason: 'y');
      });
    }

    test('scale is right at the anchor plane', () {
      // Two canonical points either side of the centroid, in the plane
      // perpendicular to a frontal view, must reproject the correct distance
      // apart: that is the whole "glasses are the right size" property.
      const scale = 3.0;
      final r = runPipeline(scale: scale);
      const cal = JeelizCubeCalibration();

      Offset projCanonical(Vec3 p) => projectThroughScene(
          r.helper.faceObject, (p - cal.origin) * (1.0 / cal.unitMm), r.camera);

      final left = projCanonical(_centroid + const Vec3(-40, 0, 0));
      final right = projCanonical(_centroid + const Vec3(40, 0, 0));
      expect(right.dx - left.dx, closeTo(80 * scale, 80 * scale * 0.01));
    });

    test('glasses land on the eyes', () {
      final r = runPipeline();
      // Centre of the lenses mesh, from models3D/glassesLenses.json's bounding
      // box, in the glasses node's local space.
      final lensPx = projectThroughScene(
          r.glasses, const Vec3(0, 33.65, 18.67), r.camera);

      // Where the eyes actually are: midpoint of the outer eye corners
      // (landmarks 33 and 263), projected from the synthetic pose.
      final lm = synthesiseLandmarks(
          rx: 0,
          ry: 0,
          rz: 0,
          scale: 3.0,
          centroidPx: const Offset(_imgW / 2, _imgH / 2));
      final eyeL = lm[33], eyeR = lm[263];
      final eyeMid = Offset((eyeL.dx + eyeR.dx) / 2 * _imgW,
          (eyeL.dy + eyeR.dy) / 2 * _imgH);

      // Within a few millimetres of the eye line — the lenses sit slightly in
      // front of and above the eye centres by design, so this is a sanity
      // bound, not an equality.
      expect((lensPx.dx - eyeMid.dx).abs(), lessThan(6));
      expect((lensPx.dy - eyeMid.dy).abs(), lessThan(6 * 3.0));
    });

    test('no landmarks holds, then drops out', () {
      final adapter = LandmarkDetectStateAdapter(smoothing: 1.0, holdFrames: 2);
      const size = Size(_imgW, _imgH);
      final lm = synthesiseLandmarks(
          rx: 0, ry: 0, rz: 0, scale: 3, centroidPx: const Offset(360, 640));

      final cam = PerspectiveCamera(fov: 62.2, aspect: 0.5625)
        ..updateProjectionMatrix();
      final first = adapter.convert(lm, size, cam);
      expect(first.detected, 1.0);
      expect(adapter.convert(null, size, cam).detected, 1.0);
      expect(adapter.convert(null, size, cam).detected, 1.0);
      expect(adapter.convert(null, size, cam).detected, 0.0);
    });
  });

  group('rasteriser', () {
    BufferGeometry quad(double z) {
      // Two triangles covering the whole viewport at depth z, wound
      // counter-clockwise in NDC so they survive front-face culling.
      return BufferGeometry(
        positions: Float32List.fromList(
            [-9, -9, z, 9, -9, z, 9, 9, z, -9, 9, z]),
        indices: Uint32List.fromList([0, 1, 2, 0, 2, 3]),
      )..computeVertexNormals();
    }

    test('depth-only occluder hides geometry behind it', () {
      final camera = PerspectiveCamera(fov: 60, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(32, 32)..clear();
      final renderer = SoftwareRenderer();

      final scene = Scene();
      // Occluder nearer the camera than the visible quad.
      scene.add(Mesh(quad(-5), OccluderMaterial())..renderOrder = -1);
      scene.add(Mesh(quad(-10), _SolidMaterial()));

      renderer.render(scene, camera, fb);

      // Nothing should have been painted: the occluder claimed every pixel.
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('geometry in front of the occluder still draws', () {
      final camera = PerspectiveCamera(fov: 60, aspect: 1, near: 0.1, far: 100)
        ..updateProjectionMatrix();
      final fb = Framebuffer(32, 32)..clear();
      final renderer = SoftwareRenderer();

      final scene = Scene();
      scene.add(Mesh(quad(-10), OccluderMaterial())..renderOrder = -1);
      scene.add(Mesh(quad(-5), _SolidMaterial()));

      renderer.render(scene, camera, fb);

      const centre = (16 * 32 + 16) * 4;
      expect(fb.color[centre + 3], 255, reason: 'alpha at centre');
      expect(fb.color[centre], 255, reason: 'red at centre');
    });
  });

  group('geometry loader', () {
    test('parses the io_three BufferGeometry shape', () {
      final g = parseBufferGeometryJson(const {
        'metadata': {'type': 'BufferGeometry'},
        'data': {
          'attributes': {
            'position': {
              'itemSize': 3,
              'type': 'Float32Array',
              'array': [0, 0, 0, 1, 0, 0, 0, 1, 0],
            }
          },
          'index': {
            'itemSize': 1,
            'type': 'Uint16Array',
            'array': [0, 1, 2],
          },
        },
      });

      expect(g.vertexCount, 3);
      expect(g.triangleCount, 1);
      g.computeVertexNormals();
      // A triangle in the z=0 plane wound CCW has +Z normals.
      expect(g.normals[2], closeTo(1.0, 1e-9));
    });
  });
}

/// Opaque red, so a drawn pixel is unmistakable.
class _SolidMaterial extends Material {
  @override
  bool shade(Fragment f, Float64List out) {
    out[0] = 1;
    out[1] = 0;
    out[2] = 0;
    out[3] = 1;
    return true;
  }
}
