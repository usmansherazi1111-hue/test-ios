// A glTF 2.0 reader, scoped to what demos/threejs/gltf_fullScreen needs.
//
// Not a general loader. glTF is a large format and the DamagedHelmet uses a
// small, very common corner of it: one buffer in an external `.bin`, four
// accessors, one mesh with one primitive, one node with a rotation, and one
// metallic-roughness material with five textures. Everything here is driven by
// that, and anything outside it throws rather than guessing — a silent wrong
// answer from a geometry loader is much worse than a stack trace.
//
// What is supported: external and embedded (base64 data:) buffers, byte
// strides, the five scalar component types, SCALAR/VEC2/VEC3/VEC4, node
// translation/rotation/scale and node matrices, and metallic-roughness
// materials. What is not: sparse accessors, animations, skins, cameras,
// morph targets, KHR extensions, and .glb containers.

import 'dart:convert';
import 'dart:typed_data';

import '../math/vec_mat.dart';
import 'geometry.dart';

/// Everything read out of a glTF file.
class GltfDocument {
  GltfDocument({
    required this.nodes,
    required this.roots,
    required this.materials,
  });

  /// All nodes, in file order.
  final List<GltfNode> nodes;

  /// Indices into [nodes] of the default scene's roots.
  final List<int> roots;

  final List<GltfMaterial> materials;

  /// Every primitive in the document, paired with the world transform of the
  /// node holding it.
  ///
  /// glTF's node tree is flattened here because nothing in this demo animates
  /// it: three keeps the hierarchy, but a static tree and its baked transforms
  /// draw identically.
  List<GltfPrimitiveInstance> flatten() {
    final out = <GltfPrimitiveInstance>[];
    void walk(int index, Mat4 parent) {
      final node = nodes[index];
      final world = parent * node.localMatrix;
      for (final p in node.primitives) {
        out.add(GltfPrimitiveInstance(primitive: p, worldMatrix: world));
      }
      for (final c in node.children) {
        walk(c, world);
      }
    }

    for (final r in roots) {
      walk(r, Mat4.identity());
    }
    return out;
  }
}

class GltfNode {
  GltfNode({
    required this.name,
    required this.localMatrix,
    required this.children,
    required this.primitives,
  });

  final String name;
  final Mat4 localMatrix;
  final List<int> children;
  final List<GltfPrimitive> primitives;
}

class GltfPrimitive {
  GltfPrimitive({required this.geometry, required this.materialIndex});

  final BufferGeometry geometry;

  /// Index into [GltfDocument.materials], or null for glTF's default material.
  final int? materialIndex;
}

class GltfPrimitiveInstance {
  GltfPrimitiveInstance({required this.primitive, required this.worldMatrix});

  final GltfPrimitive primitive;
  final Mat4 worldMatrix;
}

/// A texture reference: which image, and which UV set.
class GltfTextureRef {
  const GltfTextureRef(this.imageUri, {this.texCoord = 0, this.scale = 1.0});

  /// The image's `uri`, relative to the glTF file.
  final String imageUri;

  final int texCoord;

  /// `normalTexture.scale` or `occlusionTexture.strength`; 1 elsewhere.
  final double scale;
}

/// A `pbrMetallicRoughness` material, with glTF's defaults already applied.
class GltfMaterial {
  GltfMaterial({
    required this.name,
    this.baseColorFactor = const <double>[1, 1, 1, 1],
    this.metallicFactor = 1.0,
    this.roughnessFactor = 1.0,
    this.emissiveFactor = const <double>[0, 0, 0],
    this.baseColorTexture,
    this.metallicRoughnessTexture,
    this.normalTexture,
    this.occlusionTexture,
    this.emissiveTexture,
    this.doubleSided = false,
  });

  final String name;

  /// Defaults are glTF's, not three's: `baseColorFactor` white,
  /// **`metallicFactor` and `roughnessFactor` both 1**. A model that omits
  /// them — as this one does — is fully metallic and fully rough before its
  /// textures modulate it.
  final List<double> baseColorFactor;
  final double metallicFactor;
  final double roughnessFactor;
  final List<double> emissiveFactor;

  final GltfTextureRef? baseColorTexture;

  /// One texture with roughness in **green** and metalness in **blue**. three
  /// assigns it to both `roughnessMap` and `metalnessMap`, which then read
  /// `.g` and `.b` respectively.
  final GltfTextureRef? metallicRoughnessTexture;

  final GltfTextureRef? normalTexture;
  final GltfTextureRef? occlusionTexture;
  final GltfTextureRef? emissiveTexture;

  final bool doubleSided;
}

/// Reads a glTF document.
///
/// [json] is the file's text. [resolveBuffer] is handed each buffer's `uri`
/// and must return its bytes; embedded `data:` URIs are decoded here and never
/// reach it.
Future<GltfDocument> parseGltf(
  String json,
  Future<Uint8List> Function(String uri) resolveBuffer,
) async {
  final root = jsonDecode(json) as Map<String, dynamic>;

  final asset = root['asset'] as Map<String, dynamic>?;
  final version = asset?['version']?.toString();
  if (version == null || !version.startsWith('2')) {
    throw FormatException('glTF $version is not supported; this reads 2.x');
  }

  // --- buffers ------------------------------------------------------------
  final buffers = <Uint8List>[];
  for (final b in (root['buffers'] as List? ?? const [])) {
    final uri = (b as Map<String, dynamic>)['uri'] as String?;
    if (uri == null) {
      throw const FormatException(
          'glTF buffer with no uri — .glb containers are not supported');
    }
    buffers.add(uri.startsWith('data:')
        ? base64Decode(uri.substring(uri.indexOf(',') + 1))
        : await resolveBuffer(uri));
  }

  final bufferViews = (root['bufferViews'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final accessors =
      (root['accessors'] as List? ?? const []).cast<Map<String, dynamic>>();

  // --- images and textures ------------------------------------------------
  final images = <String>[
    for (final i in (root['images'] as List? ?? const []))
      ((i as Map<String, dynamic>)['uri'] as String?) ??
          (throw const FormatException(
              'glTF image with no uri — bufferView images are not supported')),
  ];
  final textureSources = <int>[
    for (final t in (root['textures'] as List? ?? const []))
      (t as Map<String, dynamic>)['source'] as int,
  ];

  GltfTextureRef? textureRef(Object? def, {String scaleKey = ''}) {
    if (def == null) return null;
    final m = def as Map<String, dynamic>;
    final index = m['index'] as int;
    final scale = scaleKey.isEmpty
        ? 1.0
        : ((m[scaleKey] as num?)?.toDouble() ?? 1.0);
    return GltfTextureRef(
      images[textureSources[index]],
      texCoord: (m['texCoord'] as int?) ?? 0,
      scale: scale,
    );
  }

  // --- materials ----------------------------------------------------------
  final materials = <GltfMaterial>[];
  for (final m in (root['materials'] as List? ?? const [])) {
    final def = m as Map<String, dynamic>;
    final pbr = def['pbrMetallicRoughness'] as Map<String, dynamic>? ?? const {};
    materials.add(GltfMaterial(
      name: (def['name'] as String?) ?? 'material${materials.length}',
      baseColorFactor: _doubles(pbr['baseColorFactor']) ?? const [1, 1, 1, 1],
      metallicFactor: (pbr['metallicFactor'] as num?)?.toDouble() ?? 1.0,
      roughnessFactor: (pbr['roughnessFactor'] as num?)?.toDouble() ?? 1.0,
      emissiveFactor: _doubles(def['emissiveFactor']) ?? const [0, 0, 0],
      baseColorTexture: textureRef(pbr['baseColorTexture']),
      metallicRoughnessTexture: textureRef(pbr['metallicRoughnessTexture']),
      normalTexture: textureRef(def['normalTexture'], scaleKey: 'scale'),
      occlusionTexture:
          textureRef(def['occlusionTexture'], scaleKey: 'strength'),
      emissiveTexture: textureRef(def['emissiveTexture']),
      doubleSided: (def['doubleSided'] as bool?) ?? false,
    ));
  }

  // --- meshes -------------------------------------------------------------
  final meshes = <List<GltfPrimitive>>[];
  for (final meshDef in (root['meshes'] as List? ?? const [])) {
    final prims = <GltfPrimitive>[];
    for (final p in ((meshDef as Map<String, dynamic>)['primitives'] as List)) {
      final prim = p as Map<String, dynamic>;

      final mode = (prim['mode'] as int?) ?? 4;
      if (mode != 4) {
        throw FormatException('glTF primitive mode $mode is not supported; '
            'only TRIANGLES (4) is');
      }

      final attrs = prim['attributes'] as Map<String, dynamic>;
      final positions =
          _readFloats(attrs['POSITION'] as int, accessors, bufferViews, buffers, 3);

      Float32List? normals;
      if (attrs.containsKey('NORMAL')) {
        normals = _readFloats(
            attrs['NORMAL'] as int, accessors, bufferViews, buffers, 3);
      }

      Float32List? uvs;
      if (attrs.containsKey('TEXCOORD_0')) {
        final raw = _readFloats(
            attrs['TEXCOORD_0'] as int, accessors, bufferViews, buffers, 2);
        // glTF's v runs **downward** from the top-left; three's textures carry
        // `flipY = true`, which flips the image rather than the coordinate, so
        // the net effect is `v -> 1 - v`. Doing it here keeps every material in
        // this package on one convention.
        //
        // This model's v values run 1.0006..1.9987 — a whole unit high — and
        // that is not a mistake to normalise away: with REPEAT wrapping it
        // samples identically, and subtracting 1 first would still give the
        // same result, so the flip is applied as-is and the wrap does the rest.
        uvs = Float32List(raw.length);
        for (var i = 0; i < raw.length; i += 2) {
          uvs[i] = raw[i];
          uvs[i + 1] = 1.0 - raw[i + 1];
        }
      }

      // The renderer's geometry always carries an index buffer, so a
      // non-indexed primitive gets a sequential one.
      final indices = prim.containsKey('indices')
          ? _readIndices(
              prim['indices'] as int, accessors, bufferViews, buffers)
          : Uint32List.fromList(
              List<int>.generate(positions.length ~/ 3, (i) => i));

      prims.add(GltfPrimitive(
        geometry: BufferGeometry(
          positions: positions,
          normals: normals,
          uvs: uvs,
          indices: indices,
        ),
        materialIndex: prim['material'] as int?,
      ));
    }
    meshes.add(prims);
  }

  // --- nodes --------------------------------------------------------------
  final nodeDefs =
      (root['nodes'] as List? ?? const []).cast<Map<String, dynamic>>();
  final nodes = <GltfNode>[];
  for (var i = 0; i < nodeDefs.length; i++) {
    final def = nodeDefs[i];
    final meshIndex = def['mesh'] as int?;
    nodes.add(GltfNode(
      name: (def['name'] as String?) ?? 'node$i',
      localMatrix: _nodeMatrix(def),
      children: ((def['children'] as List?) ?? const []).cast<int>(),
      primitives: meshIndex == null ? const [] : meshes[meshIndex],
    ));
  }

  final sceneIndex = (root['scene'] as int?) ?? 0;
  final scenes = (root['scenes'] as List? ?? const []);
  final roots = scenes.isEmpty
      ? List<int>.generate(nodes.length, (i) => i)
      : (((scenes[sceneIndex] as Map<String, dynamic>)['nodes'] as List?) ??
              const [])
          .cast<int>();

  return GltfDocument(nodes: nodes, roots: roots, materials: materials);
}

/// A node's local transform: an explicit `matrix`, or TRS composed as
/// `T * R * S`, which is glTF's stated order.
Mat4 _nodeMatrix(Map<String, dynamic> def) {
  final m = _doubles(def['matrix']);
  if (m != null) {
    // glTF matrices are column-major, which is also this package's storage
    // order, so the numbers go straight in.
    return Mat4.fromList(m);
  }

  final t = _doubles(def['translation']) ?? const [0.0, 0.0, 0.0];
  final r = _doubles(def['rotation']) ?? const [0.0, 0.0, 0.0, 1.0];
  final s = _doubles(def['scale']) ?? const [1.0, 1.0, 1.0];

  final out = quaternionToMat4(r[0], r[1], r[2], r[3]);
  // Scale the basis columns, then drop the translation in — the composition of
  // T * R * S written out.
  for (var c = 0; c < 3; c++) {
    for (var row = 0; row < 3; row++) {
      out.m[c * 4 + row] *= s[c];
    }
  }
  out.m[12] = t[0];
  out.m[13] = t[1];
  out.m[14] = t[2];
  return out;
}

/// A unit quaternion (x, y, z, w) as a rotation matrix — three's
/// `Matrix4.makeRotationFromQuaternion`.
Mat4 quaternionToMat4(double x, double y, double z, double w) {
  final x2 = x + x, y2 = y + y, z2 = z + z;
  final xx = x * x2, xy = x * y2, xz = x * z2;
  final yy = y * y2, yz = y * z2, zz = z * z2;
  final wx = w * x2, wy = w * y2, wz = w * z2;

  final out = Mat4.identity();
  final m = out.m;
  m[0] = 1 - (yy + zz);
  m[1] = xy + wz;
  m[2] = xz - wy;

  m[4] = xy - wz;
  m[5] = 1 - (xx + zz);
  m[6] = yz + wx;

  m[8] = xz + wy;
  m[9] = yz - wx;
  m[10] = 1 - (xx + yy);
  return out;
}

// --- accessor reading -------------------------------------------------------

const Map<String, int> _kComponentsPerType = <String, int>{
  'SCALAR': 1,
  'VEC2': 2,
  'VEC3': 3,
  'VEC4': 4,
};

/// glTF component type codes.
const int _kByte = 5120,
    _kUnsignedByte = 5121,
    _kShort = 5122,
    _kUnsignedShort = 5123,
    _kUnsignedInt = 5125,
    _kFloat = 5126;

int _componentBytes(int componentType) => switch (componentType) {
      _kByte || _kUnsignedByte => 1,
      _kShort || _kUnsignedShort => 2,
      _kUnsignedInt || _kFloat => 4,
      _ => throw FormatException('unknown glTF componentType $componentType'),
    };

/// Reads accessor [index] as floats, [wanted] components per element.
///
/// Integer component types are normalised to 0..1 (or -1..1 for the signed
/// ones) when the accessor says `normalized`, matching glTF's rules.
Float32List _readFloats(
  int index,
  List<Map<String, dynamic>> accessors,
  List<Map<String, dynamic>> bufferViews,
  List<Uint8List> buffers,
  int wanted,
) {
  final acc = accessors[index];
  if (acc.containsKey('sparse')) {
    throw const FormatException('sparse glTF accessors are not supported');
  }

  final type = acc['type'] as String;
  final components = _kComponentsPerType[type] ??
      (throw FormatException('unknown glTF accessor type $type'));
  if (components != wanted) {
    throw FormatException(
        'accessor $index is $type; $wanted components were expected');
  }

  final count = acc['count'] as int;
  final componentType = acc['componentType'] as int;
  final normalized = (acc['normalized'] as bool?) ?? false;
  final elementBytes = _componentBytes(componentType) * components;

  final view = bufferViews[acc['bufferView'] as int];
  final bytes = buffers[view['buffer'] as int];
  final viewOffset = (view['byteOffset'] as int?) ?? 0;
  final stride = (view['byteStride'] as int?) ?? elementBytes;
  final base = viewOffset + ((acc['byteOffset'] as int?) ?? 0);

  final data = ByteData.sublistView(bytes);
  final out = Float32List(count * components);

  for (var i = 0; i < count; i++) {
    final at = base + i * stride;
    for (var c = 0; c < components; c++) {
      final o = at + c * _componentBytes(componentType);
      final double v;
      switch (componentType) {
        case _kFloat:
          v = data.getFloat32(o, Endian.little);
        case _kUnsignedShort:
          final raw = data.getUint16(o, Endian.little);
          v = normalized ? raw / 65535.0 : raw.toDouble();
        case _kShort:
          final raw = data.getInt16(o, Endian.little);
          v = normalized ? (raw / 32767.0).clamp(-1.0, 1.0) : raw.toDouble();
        case _kUnsignedByte:
          final raw = data.getUint8(o);
          v = normalized ? raw / 255.0 : raw.toDouble();
        case _kByte:
          final raw = data.getInt8(o);
          v = normalized ? (raw / 127.0).clamp(-1.0, 1.0) : raw.toDouble();
        case _kUnsignedInt:
          v = data.getUint32(o, Endian.little).toDouble();
        default:
          throw FormatException('unknown glTF componentType $componentType');
      }
      out[i * components + c] = v;
    }
  }
  return out;
}

Uint32List _readIndices(
  int index,
  List<Map<String, dynamic>> accessors,
  List<Map<String, dynamic>> bufferViews,
  List<Uint8List> buffers,
) {
  final acc = accessors[index];
  final count = acc['count'] as int;
  final componentType = acc['componentType'] as int;
  final view = bufferViews[acc['bufferView'] as int];
  final bytes = buffers[view['buffer'] as int];
  final base = ((view['byteOffset'] as int?) ?? 0) +
      ((acc['byteOffset'] as int?) ?? 0);
  final size = _componentBytes(componentType);
  final stride = (view['byteStride'] as int?) ?? size;

  final data = ByteData.sublistView(bytes);
  final out = Uint32List(count);
  for (var i = 0; i < count; i++) {
    final o = base + i * stride;
    out[i] = switch (componentType) {
      _kUnsignedByte => data.getUint8(o),
      _kUnsignedShort => data.getUint16(o, Endian.little),
      _kUnsignedInt => data.getUint32(o, Endian.little),
      _ => throw FormatException('bad glTF index componentType $componentType'),
    };
  }
  return out;
}

List<double>? _doubles(Object? v) => v == null
    ? null
    : <double>[for (final x in v as List) (x as num).toDouble()];
