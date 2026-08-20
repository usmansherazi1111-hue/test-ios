// Indexed triangle geometry, plus a loader for the JSON that three's
// BufferGeometryLoader eats.
//
// The exports vary in how much they carry. glassesVTO's models3D/*.json hold
// positions and indices only — no normals, no UVs — which is why
// JeelizThreeGlassesCreator calls `computeVertexNormals()` right after every
// load. TigerHead.json is richer: it ships normals, UVs, and *groups* that
// slice the index buffer into four ranges, one per material (whiskers, eyes,
// face skin, inside ears). Both shapes load through the same path here.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// A slice of the index buffer drawn with one material.
///
/// three's `BufferGeometry.groups`. A mesh with a material *list* picks
/// `materials[materialIndex]` for each group; a mesh with a single material
/// ignores them.
class GeometryGroup {
  const GeometryGroup(this.start, this.count, this.materialIndex);

  /// Offset into the index buffer, in indices (not triangles).
  final int start;

  /// Number of indices in this group.
  final int count;

  final int materialIndex;
}

class BufferGeometry {
  BufferGeometry({
    required this.positions,
    required this.indices,
    Float32List? normals,
    this.uvs,
    List<GeometryGroup>? groups,
    this.morphPositions = const [],
  })  : normals = normals ?? Float32List(positions.length),
        hasSuppliedNormals = normals != null,
        groups = groups ?? const [];

  /// xyz triples, object space.
  final Float32List positions;

  /// Triangle list, 3 entries per face.
  final Uint32List indices;

  /// xyz triples, parallel to [positions]. Zero-filled until
  /// [computeVertexNormals] runs.
  final Float32List normals;

  /// uv pairs, parallel to [positions]. Null when the export has none.
  final Float32List? uvs;

  /// Material ranges. Empty means "draw the whole index buffer as one".
  final List<GeometryGroup> groups;

  /// Morph target positions, each parallel to [positions].
  ///
  /// three keeps these on the geometry and the *influences* on the mesh, and so
  /// do we — see [Mesh.morphInfluences].
  final List<Float32List> morphPositions;

  bool get hasMorphTargets => morphPositions.isNotEmpty;

  /// True when the export carried its own normals, so smoothing them again
  /// would throw away the artist's hard edges.
  final bool hasSuppliedNormals;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  /// Area-weighted smooth normals, the same accumulate-then-normalise scheme
  /// three uses. Face normals are *not* normalised before accumulation, so
  /// larger triangles pull harder — that is deliberate and matches three.
  void computeVertexNormals() {
    final n = normals;
    for (var i = 0; i < n.length; i++) {
      n[i] = 0;
    }

    final p = positions;
    for (var f = 0; f < indices.length; f += 3) {
      final ia = indices[f] * 3, ib = indices[f + 1] * 3, ic = indices[f + 2] * 3;

      final ax = p[ia], ay = p[ia + 1], az = p[ia + 2];
      final e1x = p[ib] - ax, e1y = p[ib + 1] - ay, e1z = p[ib + 2] - az;
      final e2x = p[ic] - ax, e2y = p[ic + 1] - ay, e2z = p[ic + 2] - az;

      final cx = e1y * e2z - e1z * e2y;
      final cy = e1z * e2x - e1x * e2z;
      final cz = e1x * e2y - e1y * e2x;

      n[ia] += cx;
      n[ia + 1] += cy;
      n[ia + 2] += cz;
      n[ib] += cx;
      n[ib + 1] += cy;
      n[ib + 2] += cz;
      n[ic] += cx;
      n[ic + 1] += cy;
      n[ic + 2] += cz;
    }

    for (var i = 0; i < n.length; i += 3) {
      final x = n[i], y = n[i + 1], z = n[i + 2];
      final l = math.sqrt(x * x + y * y + z * z);
      if (l > 1e-12) {
        n[i] = x / l;
        n[i + 1] = y / l;
        n[i + 2] = z / l;
      } else {
        n[i + 2] = 1;
      }
    }
  }

  /// Bounding box, as `[minX, minY, minZ, maxX, maxY, maxZ]`. Only used for
  /// diagnostics and for the renderer's screen-bounds estimate.
  Float64List computeBoundingBox() {
    final r = Float64List.fromList(
        [double.infinity, double.infinity, double.infinity, -double.infinity, -double.infinity, -double.infinity]);
    for (var i = 0; i < positions.length; i += 3) {
      for (var k = 0; k < 3; k++) {
        final v = positions[i + k];
        if (v < r[k]) r[k] = v;
        if (v > r[k + 3]) r[k + 3] = v;
      }
    }
    return r;
  }
}

/// Which axis [sortGeometryFaces] orders triangles along.
enum SortAxis { x, y, z }

/// Port of `JeelizThreeHelper.sortFaces(bufferGeometry, axis, isInv)`.
///
/// Reorders the index buffer so triangles come out sorted by the centroid of
/// their vertices along one axis, in **object space**. Its own comment explains
/// why: "Useful when a bufferGeometry has alpha: we should render the last
/// faces first." Without it a transparent mesh composites in whatever order
/// the exporter happened to emit.
///
/// [inverted] reverses the order, which is what both multiLiberty meshes ask
/// for (`sortFaces(geom, 'z', true)`).
///
/// Mutates [geometry]'s index buffer in place, as the original does.
void sortGeometryFaces(BufferGeometry geometry, SortAxis axis,
    {bool inverted = false}) {
  final idx = geometry.indices;
  final pos = geometry.positions;
  final nFaces = idx.length ~/ 3;
  if (nFaces < 2) return;

  final offset = axis.index;
  final sortWay = inverted ? -1.0 : 1.0;

  // Centroid along the chosen axis, per face.
  final key = Float64List(nFaces);
  final order = List<int>.generate(nFaces, (i) => i, growable: false);

  for (var i = 0; i < nFaces; i++) {
    final a = idx[3 * i] * 3 + offset;
    final b = idx[3 * i + 1] * 3 + offset;
    final c = idx[3 * i + 2] * 3 + offset;
    key[i] = (pos[a] + pos[b] + pos[c]) / 3.0;
  }

  order.sort((a, b) => ((key[a] - key[b]) * sortWay).sign.toInt());

  // Rewrite the index buffer in the new order. A copy of the original is
  // needed because the destination is the same buffer being read.
  final src = Uint32List.fromList(idx);
  for (var i = 0; i < nFaces; i++) {
    final f = order[i];
    idx[3 * i] = src[3 * f];
    idx[3 * i + 1] = src[3 * f + 1];
    idx[3 * i + 2] = src[3 * f + 2];
  }
}

/// Parses the object three's `BufferGeometryLoader.parse` accepts.
///
/// Only the attributes these demos ship are honoured (position, optional
/// normal/uv). Anything else is ignored rather than throwing, so a richer
/// export still loads instead of failing at runtime.
BufferGeometry parseBufferGeometryJson(Map<String, dynamic> json) {
  final data = (json['data'] ?? json) as Map<String, dynamic>;
  final attributes = data['attributes'] as Map<String, dynamic>?;
  if (attributes == null || attributes['position'] == null) {
    throw const FormatException(
        'BufferGeometry JSON has no data.attributes.position');
  }

  final posArray = (attributes['position'] as Map)['array'] as List;
  final positions = Float32List(posArray.length);
  for (var i = 0; i < posArray.length; i++) {
    positions[i] = (posArray[i] as num).toDouble();
  }

  Uint32List indices;
  final indexNode = data['index'];
  if (indexNode is Map && indexNode['array'] is List) {
    final src = indexNode['array'] as List;
    indices = Uint32List(src.length);
    for (var i = 0; i < src.length; i++) {
      indices[i] = (src[i] as num).toInt();
    }
  } else {
    // Non-indexed export: synthesise a trivial index buffer so the rest of
    // the pipeline only ever deals with one case.
    final count = positions.length ~/ 3;
    indices = Uint32List(count);
    for (var i = 0; i < count; i++) {
      indices[i] = i;
    }
  }

  Float32List? normals;
  final normalNode = attributes['normal'];
  if (normalNode is Map && normalNode['array'] is List) {
    final src = normalNode['array'] as List;
    normals = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      normals[i] = (src[i] as num).toDouble();
    }
  }

  Float32List? uvs;
  final uvNode = attributes['uv'];
  if (uvNode is Map && uvNode['array'] is List) {
    final src = uvNode['array'] as List;
    uvs = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      uvs[i] = (src[i] as num).toDouble();
    }
  }

  final groups = <GeometryGroup>[];
  final groupNode = data['groups'];
  if (groupNode is List) {
    for (final g in groupNode) {
      if (g is! Map) continue;
      groups.add(GeometryGroup(
        (g['start'] as num?)?.toInt() ?? 0,
        (g['count'] as num?)?.toInt() ?? 0,
        (g['materialIndex'] as num?)?.toInt() ?? 0,
      ));
    }
  }

  return BufferGeometry(
    positions: positions,
    indices: indices,
    normals: normals,
    uvs: uvs,
    groups: groups,
  );
}

/// Loads and parses a geometry from the asset bundle.
///
/// [computeNormals] defaults to true because the Jeeliz exports carry none and
/// every call site in the original JS immediately computes them.
Future<BufferGeometry> loadBufferGeometry(
  String assetKey, {
  bool computeNormals = true,
}) async {
  final text = await rootBundle.loadString(assetKey);
  return decodeBufferGeometry(text, computeNormals: computeNormals);
}

/// Parses geometry from already-loaded JSON text. Used by the filters, which
/// resolve their own asset keys — see `loadJeelizAssetString`.
///
/// [computeNormals] only fires when the export did *not* ship normals.
/// TigerHead.json does ship them, and re-smoothing would round off the hard
/// creases the model was authored with.
BufferGeometry decodeBufferGeometry(String json,
    {bool computeNormals = true}) {
  final geom =
      parseBufferGeometryJson(jsonDecode(json) as Map<String, dynamic>);
  if (computeNormals && !geom.hasSuppliedNormals) geom.computeVertexNormals();
  return geom;
}
