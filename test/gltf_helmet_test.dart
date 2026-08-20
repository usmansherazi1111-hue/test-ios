// Tests for demos/threejs/gltf_fullScreen, and for the three pieces of core it
// needed: a glTF 2.0 reader, a mipmapped cube map, and the rest of
// MeshStandardMaterial.
//
// The loader tests are the important ones. A geometry reader that is subtly
// wrong produces a model that looks *almost* right, which is much harder to
// notice than one that throws — so accessor decoding, strides, component types
// and the UV flip are all pinned against hand-built files.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeliz_dart/jeeliz_dart.dart';

/// Builds a one-primitive glTF around [bin], for the loader tests.
String miniGltf({
  required Map<String, dynamic> accessors,
  required List<Map<String, dynamic>> bufferViews,
  required Map<String, dynamic> attributes,
  int? indices,
  List<Map<String, dynamic>>? nodes,
  List<Map<String, dynamic>>? materials,
  int byteLength = 4096,
}) {
  return jsonEncode(<String, dynamic>{
    'asset': {'version': '2.0'},
    'buffers': [
      {'uri': 'data.bin', 'byteLength': byteLength}
    ],
    'bufferViews': bufferViews,
    'accessors': accessors['list'],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': attributes,
            if (indices != null) 'indices': indices,
            if (materials != null) 'material': 0,
          }
        ]
      }
    ],
    'materials': materials ?? const [],
    'nodes': nodes ?? [
      {'mesh': 0}
    ],
    'scenes': [
      {
        'nodes': [0]
      }
    ],
    'scene': 0,
  });
}

Uint8List floats(List<double> v) {
  final b = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    b.setFloat32(i * 4, v[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the glTF reader', () {
    test('reads positions, normals, UVs and indices', () async {
      // A single triangle: 3 positions, 3 normals, 3 UVs, 3 indices.
      final bin = BytesBuilder()
        ..add(floats(const [0, 0, 0, 1, 0, 0, 0, 1, 0])) // POSITION, 36 bytes
        ..add(floats(const [0, 0, 1, 0, 0, 1, 0, 0, 1])) // NORMAL, 36
        ..add(floats(const [0, 0, 1, 0, 0, 1])); // TEXCOORD_0, 24
      final indexBytes = ByteData(6)
        ..setUint16(0, 0, Endian.little)
        ..setUint16(2, 1, Endian.little)
        ..setUint16(4, 2, Endian.little);
      final bytes =
          Uint8List.fromList(bin.toBytes() + indexBytes.buffer.asUint8List());

      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
          {'buffer': 0, 'byteOffset': 36, 'byteLength': 36},
          {'buffer': 0, 'byteOffset': 72, 'byteLength': 24},
          {'buffer': 0, 'byteOffset': 96, 'byteLength': 6},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
            {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
            {'bufferView': 2, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
            {
              'bufferView': 3,
              'componentType': 5123,
              'count': 3,
              'type': 'SCALAR'
            },
          ]
        },
        attributes: {'POSITION': 0, 'NORMAL': 1, 'TEXCOORD_0': 2},
        indices: 3,
      );

      final doc = await parseGltf(json, (_) async => bytes);
      final g = doc.flatten().single.primitive.geometry;

      expect(g.positions, [0, 0, 0, 1, 0, 0, 0, 1, 0]);
      expect(g.normals, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
      expect(g.hasSuppliedNormals, isTrue);
      expect(g.indices, [0, 1, 2]);
    });

    test('flips v, because glTF counts it downward', () async {
      // glTF's origin is top-left; three carries `flipY = true` on its
      // textures, so the net effect is v -> 1 - v.
      final bytes = Uint8List.fromList(
          floats(const [0, 0, 0, 1, 0, 0, 0, 1, 0]) +
              floats(const [0.0, 0.25, 1.0, 0.75, 0.5, 1.0]));

      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
          {'buffer': 0, 'byteOffset': 36, 'byteLength': 24},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
            {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
          ]
        },
        attributes: {'POSITION': 0, 'TEXCOORD_0': 1},
      );

      final doc = await parseGltf(json, (_) async => bytes);
      final uvs = doc.flatten().single.primitive.geometry.uvs!;
      expect(uvs[0], closeTo(0.0, 1e-6));
      expect(uvs[1], closeTo(0.75, 1e-6));
      expect(uvs[3], closeTo(0.25, 1e-6));
      expect(uvs[5], closeTo(0.0, 1e-6));
    });

    test('honours byteStride, so interleaved buffers work', () async {
      // Two vertices of (position, padding) at a 16-byte stride.
      final b = ByteData(32);
      b
        ..setFloat32(0, 1, Endian.little)
        ..setFloat32(4, 2, Endian.little)
        ..setFloat32(8, 3, Endian.little)
        ..setFloat32(12, 999, Endian.little) // padding
        ..setFloat32(16, 4, Endian.little)
        ..setFloat32(20, 5, Endian.little)
        ..setFloat32(24, 6, Endian.little)
        ..setFloat32(28, 999, Endian.little);

      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 32, 'byteStride': 16},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 2, 'type': 'VEC3'},
          ]
        },
        attributes: {'POSITION': 0},
      );

      final doc = await parseGltf(json, (_) async => b.buffer.asUint8List());
      expect(doc.flatten().single.primitive.geometry.positions,
          [1, 2, 3, 4, 5, 6]);
    });

    test('normalises integer accessors when asked', () async {
      // A UV set stored as normalized unsigned shorts: 65535 -> 1.0, 0 -> 0.0.
      final b = ByteData(4)
        ..setUint16(0, 65535, Endian.little)
        ..setUint16(2, 0, Endian.little);
      final bytes = Uint8List(16);
      bytes.setRange(0, 4, b.buffer.asUint8List());
      bytes.setRange(4, 16, floats(const [1, 2, 3]));

      final json = jsonEncode(<String, dynamic>{
        'asset': {'version': '2.0'},
        'buffers': [
          {'uri': 'b.bin', 'byteLength': 16}
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 4},
          {'buffer': 0, 'byteOffset': 4, 'byteLength': 12},
        ],
        'accessors': [
          {
            'bufferView': 0,
            'componentType': 5123,
            'count': 1,
            'type': 'VEC2',
            'normalized': true,
          },
          {'bufferView': 1, 'componentType': 5126, 'count': 1, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 1, 'TEXCOORD_0': 0}
              }
            ]
          }
        ],
        'nodes': [
          {'mesh': 0}
        ],
      });

      final doc = await parseGltf(json, (_) async => bytes);
      final uvs = doc.flatten().single.primitive.geometry.uvs!;
      expect(uvs[0], closeTo(1.0, 1e-4));
      // v is flipped on the way in, so a stored 0 comes out as 1.
      expect(uvs[1], closeTo(1.0, 1e-4));
    });

    test('composes a node quaternion the way three does', () async {
      // The helmet's node: a +90 degree rotation about X, which stands it up.
      final m = quaternionToMat4(0.7071068, 0, 0, 0.7071068);
      // Y should map to Z, and Z to -Y.
      double at(int c, int r) => m.m[c * 4 + r];
      expect(at(1, 2), closeTo(1.0, 1e-5), reason: 'Y column points along +Z');
      expect(at(2, 1), closeTo(-1.0, 1e-5), reason: 'Z column points along -Y');
      expect(at(0, 0), closeTo(1.0, 1e-5), reason: 'X unchanged');
    });

    test('composes TRS as T * R * S', () async {
      final bytes = Uint8List.fromList(floats(const [1, 0, 0]));
      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'},
          ]
        },
        attributes: {'POSITION': 0},
        nodes: [
          {
            'mesh': 0,
            'translation': [10.0, 0.0, 0.0],
            'scale': [2.0, 3.0, 4.0],
          }
        ],
      );

      final doc = await parseGltf(json, (_) async => bytes);
      final w = doc.flatten().single.worldMatrix.m;
      expect(w[0], 2.0);
      expect(w[5], 3.0);
      expect(w[10], 4.0);
      expect(w[12], 10.0);
    });

    test('an explicit node matrix goes straight in, column-major', () async {
      final bytes = Uint8List.fromList(floats(const [1, 0, 0]));
      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'},
          ]
        },
        attributes: {'POSITION': 0},
        nodes: [
          {
            'mesh': 0,
            'matrix': [
              1.0, 0.0, 0.0, 0.0, //
              0.0, 1.0, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              7.0, 8.0, 9.0, 1.0,
            ],
          }
        ],
      );
      final doc = await parseGltf(json, (_) async => bytes);
      final w = doc.flatten().single.worldMatrix.m;
      expect([w[12], w[13], w[14]], [7.0, 8.0, 9.0]);
    });

    test('applies glTF material defaults, which are not three\'s', () async {
      // A material that names no factors is fully metallic and fully rough.
      final bytes = Uint8List.fromList(floats(const [1, 0, 0]));
      final json = miniGltf(
        bufferViews: [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12},
        ],
        accessors: {
          'list': [
            {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'},
          ]
        },
        attributes: {'POSITION': 0},
        materials: [
          {'name': 'bare', 'pbrMetallicRoughness': <String, dynamic>{}}
        ],
      );
      final doc = await parseGltf(json, (_) async => bytes);
      final m = doc.materials.single;
      expect(m.metallicFactor, 1.0);
      expect(m.roughnessFactor, 1.0);
      expect(m.baseColorFactor, [1, 1, 1, 1]);
      expect(m.emissiveFactor, [0, 0, 0]);
    });

    test('refuses what it does not implement, instead of guessing', () async {
      final bytes = Uint8List(64);
      Future<void> expectThrows(String json) async {
        await expectLater(
            parseGltf(json, (_) async => bytes), throwsFormatException);
      }

      // glTF 1.0.
      await expectThrows(jsonEncode({
        'asset': {'version': '1.0'},
        'buffers': [],
      }));

      // A .glb-style buffer with no uri.
      await expectThrows(jsonEncode({
        'asset': {'version': '2.0'},
        'buffers': [
          {'byteLength': 4}
        ],
      }));

      // A non-triangle primitive.
      await expectThrows(jsonEncode({
        'asset': {'version': '2.0'},
        'buffers': [
          {'uri': 'b.bin', 'byteLength': 64}
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12}
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'}
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
                'mode': 1,
              }
            ]
          }
        ],
        'nodes': [
          {'mesh': 0}
        ],
      }));
    });

    test('decodes a base64 buffer without touching the resolver', () async {
      final data = base64Encode(floats(const [1, 2, 3]));
      final json = jsonEncode({
        'asset': {'version': '2.0'},
        'buffers': [
          {'uri': 'data:application/octet-stream;base64,$data'}
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12}
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'}
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0}
              }
            ]
          }
        ],
        'nodes': [
          {'mesh': 0}
        ],
      });

      var resolverCalled = false;
      final doc = await parseGltf(json, (_) async {
        resolverCalled = true;
        return Uint8List(0);
      });
      expect(resolverCalled, isFalse);
      expect(doc.flatten().single.primitive.geometry.positions, [1, 2, 3]);
    });
  });

  group('CubeTexture', () {
    /// A cube whose six faces are six distinct flat colours.
    CubeTexture colouredCube(int size) {
      const colours = <List<int>>[
        [255, 0, 0], // +X
        [0, 255, 0], // -X
        [0, 0, 255], // +Y
        [255, 255, 0], // -Y
        [255, 0, 255], // +Z
        [0, 255, 255], // -Z
      ];
      return CubeTexture.fromFaces(size, <Uint8List>[
        for (final c in colours)
          Uint8List.fromList(<int>[
            for (var i = 0; i < size * size; i++) ...[c[0], c[1], c[2], 255]
          ]),
      ]);
    }

    test('picks the face from the largest axis', () {
      final cube = colouredCube(4);
      final out = Float64List(3);

      void expectFace(double x, double y, double z, List<double> want) {
        cube.sampleDirection(x, y, z, 0, out);
        expect(out[0], closeTo(want[0], 0.02), reason: 'dir ($x,$y,$z)');
        expect(out[1], closeTo(want[1], 0.02), reason: 'dir ($x,$y,$z)');
        expect(out[2], closeTo(want[2], 0.02), reason: 'dir ($x,$y,$z)');
      }

      expectFace(1, 0, 0, const [1, 0, 0]);
      expectFace(-1, 0, 0, const [0, 1, 0]);
      expectFace(0, 1, 0, const [0, 0, 1]);
      expectFace(0, -1, 0, const [1, 1, 0]);
      expectFace(0, 0, 1, const [1, 0, 1]);
      expectFace(0, 0, -1, const [0, 1, 1]);
    });

    test('builds a pyramid down to 1x1', () {
      final cube = colouredCube(16);
      expect(cube.size, 16);
      expect(cube.maxMipLevel, 4);
      expect(cube.levelCount, 5);
      expect(cube.sizeOf(0), 16);
      expect(cube.sizeOf(4), 1);
    });

    test('the pyramid averages, so a checkerboard flattens at the top', () {
      const n = 8;
      final face = Uint8List(n * n * 4);
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final on = (x + y).isEven;
          final i = (y * n + x) * 4;
          face[i] = face[i + 1] = face[i + 2] = on ? 255 : 0;
          face[i + 3] = 255;
        }
      }
      final cube = CubeTexture.fromFaces(
          n, List<Uint8List>.generate(6, (_) => Uint8List.fromList(face)));

      // Sample a spread of directions across the +Z face and compare how much
      // the result varies. Level 0 swings between black and white; the top of
      // the pyramid is flat grey. (A single centred sample proves nothing —
      // dead centre of an 8x8 face lands between four texels and bilinear
      // averages the checkerboard to 0.5 at *every* level.)
      double spread(double level) {
        var lo = 1.0, hi = 0.0;
        final out = Float64List(3);
        for (var i = 0; i < 8; i++) {
          for (var j = 0; j < 8; j++) {
            final u = (i + 0.5) / 8, v = (j + 0.5) / 8;
            cube.sampleDirection(2 * u - 1, -(2 * v - 1), 1.0, level, out);
            if (out[0] < lo) lo = out[0];
            if (out[0] > hi) hi = out[0];
          }
        }
        return hi - lo;
      }

      expect(spread(0), greaterThan(0.5), reason: 'level 0 is high contrast');
      expect(spread(cube.maxMipLevel.toDouble()), lessThan(0.05),
          reason: 'the top of the pyramid is flat');
    });

    test('blends between two mip levels', () {
      const n = 4;
      // A face that is black on top and white on the bottom, so levels differ.
      final face = Uint8List(n * n * 4);
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final i = (y * n + x) * 4;
          final v = y < n ~/ 2 ? 0 : 255;
          face[i] = face[i + 1] = face[i + 2] = v;
          face[i + 3] = 255;
        }
      }
      final cube = CubeTexture.fromFaces(
          n, List<Uint8List>.generate(6, (_) => Uint8List.fromList(face)));

      final a = Float64List(3), b = Float64List(3), mid = Float64List(3);
      cube.sampleDirection(0.3, -0.9, 0.3, 0, a);
      cube.sampleDirection(0.3, -0.9, 0.3, 1, b);
      cube.sampleDirection(0.3, -0.9, 0.3, 0.5, mid);
      expect(mid[0], closeTo((a[0] + b[0]) / 2, 1e-6));
    });

    test('clamps the level to the pyramid', () {
      final cube = colouredCube(4);
      final a = Float64List(3), b = Float64List(3);
      cube.sampleDirection(1, 0, 0, -5, a);
      cube.sampleDirection(1, 0, 0, 0, b);
      expect(a, b);
      cube.sampleDirection(1, 0, 0, 99, a);
      cube.sampleDirection(1, 0, 0, cube.maxMipLevel.toDouble(), b);
      expect(a, b);
    });

    test('a solid cube is one texel per face', () {
      final cube = CubeTexture.solid(10, 20, 30);
      expect(cube.size, 1);
      expect(cube.maxMipLevel, 0);
      final out = Float64List(3);
      cube.sampleDirection(0, 0, -1, 0, out);
      expect(out[0], closeTo(10 / 255, 1e-6));
    });

    test('rejects a wrong number of faces', () {
      expect(
          () => CubeTexture.fromFaces(2, <Uint8List>[Uint8List(16)]),
          throwsArgumentError);
    });
  });

  group('specularMipLevel', () {
    test('a mirror reads level 0 and a rough surface the top', () {
      // sigma = PI*r^2/(1+r); desired = maxMip + log2(sigma), clamped.
      expect(specularMipLevel(0.0, 8), 0.0);
      expect(specularMipLevel(1.0, 8), 8.0,
          reason: 'sigma = PI/2 > 1, so it clamps to the top');
      final mid = specularMipLevel(0.5, 8);
      expect(mid, greaterThan(0.0));
      expect(mid, lessThan(8.0));
      // Explicitly: sigma = PI*0.25/1.5 = 0.5236, log2 = -0.933.
      expect(mid, closeTo(8 + math.log(math.pi * 0.25 / 1.5) / math.ln2, 1e-9));
    });

    test('is monotone in roughness', () {
      var last = -1.0;
      for (var r = 0.0; r <= 1.0; r += 0.05) {
        final l = specularMipLevel(r, 7);
        expect(l, greaterThanOrEqualTo(last));
        last = l;
      }
    });
  });

  group('srgbToLinear', () {
    test('darkens midtones and pins the ends', () {
      expect(srgbToLinear(0.0), closeTo(0.0, 1e-9));
      expect(srgbToLinear(1.0), closeTo(1.0, 1e-6));
      // The classic check: sRGB 0.5 is about 0.214 linear.
      expect(srgbToLinear(0.5), closeTo(0.2140, 0.001));
      expect(srgbToLinear(0.5), lessThan(0.5));
    });

    test('is continuous across the piecewise join', () {
      const t = 0.04045;
      expect(srgbToLinear(t - 1e-6), closeTo(srgbToLinear(t + 1e-6), 1e-5));
    });
  });

  group('StandardMaterial with an env map', () {
    Texture2D flat(int r, int g, int b, [int a = 255]) =>
        Texture2D(1, 1, Uint8List.fromList(<int>[r, g, b, a]));

    Fragment frontFacing() => Fragment()
      ..nx = 0
      ..ny = 0
      ..nz = 1
      ..vx = 0
      ..vy = 0
      ..vz = -1;

    test('with no lights and no env map, only emissive shows', () {
      final m = StandardMaterial(
        color: const Vec3(1, 1, 1),
        metalness: 1,
        roughness: 1,
        emissive: const Vec3(0.25, 0.5, 0.75),
      );
      final out = Float64List(4);
      expect(m.shade(frontFacing(), out), isTrue);
      expect(out[0], closeTo(0.25, 1e-9));
      expect(out[1], closeTo(0.5, 1e-9));
      expect(out[2], closeTo(0.75, 1e-9));
    });

    test('a cube map alone lights a metal, which is the whole demo', () {
      // gltf_fullScreen adds no lights. Environment specular is all there is.
      final cube = CubeTexture.solid(255, 255, 255);
      final m = StandardMaterial(
        color: const Vec3(0.9, 0.6, 0.3),
        metalness: 1,
        roughness: 0.2,
        envMap: cube,
      );
      final out = Float64List(4);
      expect(m.shade(frontFacing(), out), isTrue);
      expect(out[0], greaterThan(0.1), reason: 'lit purely by reflection');
      // For metal the specular colour is the albedo, so the tint survives.
      expect(out[0], greaterThan(out[1]));
      expect(out[1], greaterThan(out[2]));
    });

    test('a dielectric reflects far less than a metal', () {
      final cube = CubeTexture.solid(255, 255, 255);
      Float64List shadeWith(double metalness) {
        final m = StandardMaterial(
          color: const Vec3(0.9, 0.6, 0.3),
          metalness: metalness,
          roughness: 0.2,
          envMap: cube,
        );
        final out = Float64List(4);
        m.shade(frontFacing(), out);
        return out;
      }

      expect(shadeWith(0.0)[0], lessThan(shadeWith(1.0)[0]));
    });

    test('roughness picks the mip, so a rough metal reads the blurred cube',
        () {
      // A cube that is bright on +Z and black elsewhere: a mirror sees the
      // bright face, a rough surface sees the average.
      const n = 4;
      Uint8List face(int v) => Uint8List.fromList(
          <int>[for (var i = 0; i < n * n; i++) ...[v, v, v, 255]]);
      final cube = CubeTexture.fromFaces(n, <Uint8List>[
        face(0), face(0), face(0), face(0), face(255), face(0),
      ]);

      double reflected(double roughness) {
        final m = StandardMaterial(
          color: const Vec3(1, 1, 1),
          metalness: 1,
          roughness: roughness,
          envMap: cube,
        );
        final out = Float64List(4);
        m.shade(frontFacing(), out);
        return out[0];
      }

      // Facing the camera, the reflection vector points back at +Z.
      expect(reflected(0.05), greaterThan(reflected(1.0)));
    });

    test('metalness and roughness come from blue and green', () {
      // glTF packs them in one texture, and three reads .b and .g.
      final packed = Texture2D(
          1, 1, Uint8List.fromList(<int>[0, 51, 255, 255])); // g=0.2, b=1.0
      final cube = CubeTexture.solid(255, 255, 255);
      final m = StandardMaterial(
        color: const Vec3(1, 1, 1),
        metalness: 1,
        roughness: 1,
        roughnessMap: packed,
        metalnessMap: packed,
        envMap: cube,
      );
      final out = Float64List(4);
      m.shade(frontFacing(), out);

      final direct = StandardMaterial(
        color: const Vec3(1, 1, 1),
        metalness: 1.0,
        roughness: 0.2,
        envMap: cube,
      );
      final want = Float64List(4);
      direct.shade(frontFacing(), want);
      expect(out[0], closeTo(want[0], 1e-9));
    });

    test('an sRGB map is decoded, and so comes out darker', () {
      final cube = CubeTexture.solid(255, 255, 255);
      final grey = flat(128, 128, 128);

      Float64List shadeWith(bool srgb) {
        final m = StandardMaterial(
          map: grey,
          mapIsSrgb: srgb,
          metalness: 1,
          roughness: 0.2,
          envMap: cube,
        );
        final out = Float64List(4);
        m.shade(frontFacing(), out);
        return out;
      }

      expect(shadeWith(true)[0], lessThan(shadeWith(false)[0]));
    });

    test('the AO map occludes indirect specular', () {
      final cube = CubeTexture.solid(255, 255, 255);
      Float64List shadeWith(int ao) {
        final m = StandardMaterial(
          color: const Vec3(1, 1, 1),
          metalness: 1,
          roughness: 0.5,
          aoMap: Texture2D(1, 1, Uint8List.fromList(<int>[ao, ao, ao, 255])),
          envMap: cube,
        );
        final out = Float64List(4);
        m.shade(frontFacing(), out);
        return out;
      }

      expect(shadeWith(0)[0], lessThan(shadeWith(255)[0]));
    });

    test('emissive adds on top of everything', () {
      final cube = CubeTexture.solid(255, 255, 255);
      final base = StandardMaterial(
          color: const Vec3(1, 1, 1),
          metalness: 1,
          roughness: 0.3,
          envMap: cube);
      final glow = StandardMaterial(
        color: const Vec3(1, 1, 1),
        metalness: 1,
        roughness: 0.3,
        envMap: cube,
        emissive: const Vec3(1, 1, 1),
        emissiveMap: flat(255, 0, 0),
      );

      final a = Float64List(4), b = Float64List(4);
      base.shade(frontFacing(), a);
      glow.shade(frontFacing(), b);
      expect(b[0], closeTo(a[0] + 1.0, 1e-9));
      expect(b[1], closeTo(a[1], 1e-9), reason: 'the map is red only');
    });

    test('it declares a need for tangents only with a normal map', () {
      expect(StandardMaterial().needsTangents, isFalse);
      expect(
          StandardMaterial(normalMap: flat(128, 128, 255)).needsTangents,
          isTrue);
    });
  });

  group('the filter', () {
    test('loads the helmet, its five maps and the cube', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 64, cubeFaceMaxWidth: 16);
      await f.load();

      final helper = JeelizFaceFilterHelper();
      f.attach(helper);

      expect(f.meshes.length, 1, reason: 'one mesh, one primitive');
      final g = f.meshes.single.geometry;
      expect(g.positions.length, 14556 * 3);
      expect(g.indices.length, 46356);
      expect(g.uvs, isNotNull);
      expect(g.hasSuppliedNormals, isTrue);

      final mat = f.meshes.single.materials.single as StandardMaterial;
      expect(mat.map, isNotNull);
      expect(mat.normalMap, isNotNull);
      expect(mat.aoMap, isNotNull);
      expect(mat.emissiveMap, isNotNull);
      expect(identical(mat.roughnessMap, mat.metalnessMap), isTrue,
          reason: 'one packed texture, two roles');
      expect(mat.envMap, isNotNull);

      expect(f.envMap!.size, 16);
      expect(f.envMap!.maxMipLevel, 4);
    });

    test('the material carries glTF\'s defaults, not three\'s', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 32, cubeFaceMaxWidth: 8);
      await f.load();
      f.attach(JeelizFaceFilterHelper());
      final mat = f.meshes.single.materials.single as StandardMaterial;
      // The file names neither factor, so both are 1 — fully metallic, fully
      // rough, before the packed texture modulates them.
      expect(mat.metalness, 1.0);
      expect(mat.roughness, 1.0);
      // emissiveFactor is [1,1,1] in the file.
      expect(mat.emissive.x, 1.0);
      expect(mat.mapIsSrgb, isTrue);
      expect(mat.emissiveMapIsSrgb, isTrue);
    });

    test('centres on the bounding box and scales to width 2.5', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 32, cubeFaceMaxWidth: 8);
      await f.load();
      final helper = JeelizFaceFilterHelper();
      f.attach(helper);

      final width = f.boundsMax.x - f.boundsMin.x;
      expect(width, greaterThan(0));

      final root = helper.faceObject.children.single;
      expect(root.scale.x, closeTo(GltfHelmetFilter.kScale / width, 1e-9));
      // Centred on x and z, then lifted by offsetYZ[0].
      final cx = (f.boundsMin.x + f.boundsMax.x) / 2;
      final cy = (f.boundsMin.y + f.boundsMax.y) / 2;
      expect(root.position.x, closeTo(-cx, 1e-9));
      expect(root.position.y, closeTo(-cy + 0.3, 1e-9));
    });

    test('the node rotation stands the helmet up', () async {
      // Without it the bounding box would be deepest in Y; with it the model
      // is taller than it is deep.
      final f = GltfHelmetFilter(textureMaxWidth: 32, cubeFaceMaxWidth: 8);
      await f.load();
      f.attach(JeelizFaceFilterHelper());

      final height = f.boundsMax.y - f.boundsMin.y;
      final depth = f.boundsMax.z - f.boundsMin.z;
      expect(height, greaterThan(depth * 0.9),
          reason: 'height $height vs depth $depth');
      expect(f.meshes.single.localMatrixOverride, isNotNull);
    });

    test('draws the helmet', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 64, cubeFaceMaxWidth: 16);
      await f.load();
      final helper = JeelizFaceFilterHelper();
      final cam = helper.createCamera();
      helper.updateCamera(cam,
          canvasWidth: 240, canvasHeight: 320, videoWidth: 240, videoHeight: 320);
      f.attach(helper);

      const head =
          DetectState(detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);
      helper.update(const [head], cam);

      final fb = Framebuffer(240, 320);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);

      var lit = 0;
      for (var i = 3; i < fb.color.length; i += 4) {
        if (fb.color[i] > 0) lit++;
      }
      expect(lit, greaterThan(2000));

      // Nothing should be pure black: the emissive and the reflection both
      // contribute everywhere the helmet covers.
      var nonBlack = 0;
      for (var i = 0; i < fb.color.length; i += 4) {
        if (fb.color[i + 3] > 0 &&
            fb.color[i] + fb.color[i + 1] + fb.color[i + 2] > 0) {
          nonBlack++;
        }
      }
      expect(nonBlack, greaterThan(lit ~/ 2));
    });

    test('an undetected face draws nothing', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 32, cubeFaceMaxWidth: 8);
      await f.load();
      final helper = JeelizFaceFilterHelper();
      final cam = helper.createCamera();
      helper.updateCamera(cam,
          canvasWidth: 160, canvasHeight: 240, videoWidth: 160, videoHeight: 240);
      f.attach(helper);
      helper.update(const [DetectState.lost], cam);

      final fb = Framebuffer(160, 240);
      fb.clear();
      SoftwareRenderer().render(helper.scene, cam, fb);
      expect(fb.color.every((b) => b == 0), isTrue);
    });

    test('detach clears the scene', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 32, cubeFaceMaxWidth: 8);
      await f.load();
      final helper = JeelizFaceFilterHelper();
      f.attach(helper);
      expect(helper.faceObject.children, isNotEmpty);
      f.detach(helper);
      expect(helper.faceObject.children, isEmpty);
      expect(f.meshes, isEmpty);
    });

    test('renders within a frame budget', () async {
      final f = GltfHelmetFilter(textureMaxWidth: 256, cubeFaceMaxWidth: 64);
      await f.load();
      final helper = JeelizFaceFilterHelper();
      final cam = helper.createCamera();
      helper.updateCamera(cam,
          canvasWidth: 270, canvasHeight: 480, videoWidth: 270, videoHeight: 480);
      f.attach(helper);

      const head =
          DetectState(detected: 1, x: 0, y: 0, s: 0.35, rx: 0, ry: 0, rz: 0);
      final fb = Framebuffer(270, 480);
      final renderer = SoftwareRenderer();

      for (var i = 0; i < 2; i++) {
        helper.update(const [head], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }

      final sw = Stopwatch()..start();
      const frames = 3;
      for (var i = 0; i < frames; i++) {
        helper.update(const [head], cam);
        fb.clear();
        renderer.render(helper.scene, cam, fb);
      }
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000 / frames;
      // ignore: avoid_print
      print('gltfHelmet: ${ms.toStringAsFixed(1)} ms/frame at 270x480 '
          '(${renderer.stats})');
      expect(ms, lessThan(2000), reason: '${ms.toStringAsFixed(1)} ms/frame');
    });
  });
}
