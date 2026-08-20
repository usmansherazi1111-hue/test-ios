// Loader for three.js's *other* JSON format.
//
// Most Jeeliz models are `BufferGeometry` exports — flat attribute arrays, easy
// (see geometry.dart). dog_tongue.json is not: main.js loads it with
// `THREE.JSONLoader`, the deprecated `Geometry` format, because it carries
// morph targets and the BufferGeometry exporter of the day could not.
//
// Its `faces` array is a single packed stream. Each record starts with a
// bit-flagged type byte saying what follows:
//
//   bit 0  quad rather than triangle  (4 indices instead of 3)
//   bit 1  face material index
//   bit 3  per-vertex UV indices
//   bit 4  face normal index
//   bit 5  per-vertex normal indices
//   bit 6  face colour index
//   bit 7  per-vertex colour indices
//
// so the stride varies record to record and the whole thing has to be walked in
// order. dog_tongue.json uses type 41 = quad + per-vertex UV + per-vertex
// normal.
//
// Vertex data is de-indexed on the way out: `Geometry` allows a face to pick
// different UV and normal indices than its position indices, which a single
// shared vertex buffer cannot express. So this emits one vertex per face corner
// and a trivial index buffer, matching what three's own
// `BufferGeometry.fromGeometry()` does.

import 'dart:convert';
import 'dart:typed_data';

import 'geometry.dart';

/// A `Geometry` JSON parsed into renderable form.
class LegacyGeometry {
  LegacyGeometry(this.geometry, this.morphFrames, this.morphNames);

  /// De-indexed positions/normals/UVs, ready to render.
  final BufferGeometry geometry;

  /// One entry per morph target, each parallel to `geometry.positions` — i.e.
  /// already de-indexed the same way, so a frame can be swapped in wholesale.
  final List<Float32List> morphFrames;

  /// Morph target names, in file order.
  final List<String> morphNames;

  bool get hasMorphTargets => morphFrames.isNotEmpty;
}

LegacyGeometry parseLegacyGeometryJson(Map<String, dynamic> json) {
  final verts = _numList(json['vertices']);
  if (verts.isEmpty) {
    throw const FormatException('Geometry JSON has no vertices');
  }

  final normals = _numList(json['normals']);

  // `uvs` is a list of UV *layers*; only the first is ever used here.
  final uvLayers = json['uvs'];
  List<double> uvs = const [];
  if (uvLayers is List && uvLayers.isNotEmpty) {
    uvs = _numList(uvLayers.first);
  }

  final faces = _numList(json['faces']);

  // Morph targets, still in position-index space.
  final morphSrc = <List<double>>[];
  final morphNames = <String>[];
  final mt = json['morphTargets'];
  if (mt is List) {
    for (final m in mt) {
      if (m is! Map) continue;
      morphSrc.add(_numList(m['vertices']));
      morphNames.add((m['name'] ?? 'morph${morphNames.length}').toString());
    }
  }

  // --- walk the packed face stream -----------------------------------
  final outPos = <double>[];
  final outNrm = <double>[];
  final outUv = <double>[];
  // Which source vertex each emitted corner came from, so morph frames can be
  // de-indexed identically afterwards.
  final srcVertex = <int>[];

  var anyNormal = false;
  var anyUv = false;

  var o = 0;
  while (o < faces.length) {
    final type = faces[o++].toInt();
    final isQuad = (type & 1) != 0;
    final hasMaterial = (type & 2) != 0;
    final hasFaceVertexUv = (type & 8) != 0;
    final hasFaceNormal = (type & 16) != 0;
    final hasFaceVertexNormal = (type & 32) != 0;
    final hasFaceColor = (type & 64) != 0;
    final hasFaceVertexColor = (type & 128) != 0;

    final nCorners = isQuad ? 4 : 3;

    final vi = List<int>.generate(nCorners, (_) => faces[o++].toInt());
    if (hasMaterial) o++;

    List<int>? uvi;
    if (hasFaceVertexUv) {
      uvi = List<int>.generate(nCorners, (_) => faces[o++].toInt());
    }
    if (hasFaceNormal) o++;
    List<int>? ni;
    if (hasFaceVertexNormal) {
      ni = List<int>.generate(nCorners, (_) => faces[o++].toInt());
    }
    if (hasFaceColor) o++;
    if (hasFaceVertexColor) o += nCorners;

    // Fan the corner list into triangles: (0,1,2) and, for a quad, (0,2,3) —
    // the same split three uses.
    final tris = isQuad
        ? const [
            [0, 1, 2],
            [0, 2, 3]
          ]
        : const [
            [0, 1, 2]
          ];

    for (final t in tris) {
      for (final c in t) {
        final v = vi[c];
        srcVertex.add(v);
        outPos
          ..add(_at(verts, v * 3))
          ..add(_at(verts, v * 3 + 1))
          ..add(_at(verts, v * 3 + 2));

        // Always emit an entry, zero-filled when this particular record
        // carried none. The stream is allowed to mix records with and without
        // normals or UVs, and dropping the absent ones would shift every
        // later vertex's attributes by one — a misalignment that still parses
        // and still renders, just wrongly.
        if (ni != null && normals.isNotEmpty) {
          anyNormal = true;
          final n = ni[c];
          outNrm
            ..add(_at(normals, n * 3))
            ..add(_at(normals, n * 3 + 1))
            ..add(_at(normals, n * 3 + 2));
        } else {
          outNrm
            ..add(0)
            ..add(0)
            ..add(0);
        }

        if (uvi != null && uvs.isNotEmpty) {
          anyUv = true;
          final u = uvi[c];
          outUv
            ..add(_at(uvs, u * 2))
            ..add(_at(uvs, u * 2 + 1));
        } else {
          outUv
            ..add(0)
            ..add(0);
        }
      }
    }
  }

  final vertexCount = outPos.length ~/ 3;
  final indices = Uint32List(vertexCount);
  for (var i = 0; i < vertexCount; i++) {
    indices[i] = i;
  }

  final geometry = BufferGeometry(
    positions: Float32List.fromList(outPos),
    indices: indices,
    normals: anyNormal ? Float32List.fromList(outNrm) : null,
    uvs: anyUv ? Float32List.fromList(outUv) : null,
  );
  if (!anyNormal) geometry.computeVertexNormals();

  // De-index each morph frame through the same corner list.
  final morphFrames = <Float32List>[];
  for (final frame in morphSrc) {
    final f = Float32List(vertexCount * 3);
    for (var i = 0; i < vertexCount; i++) {
      final v = srcVertex[i] * 3;
      f[i * 3] = _at(frame, v);
      f[i * 3 + 1] = _at(frame, v + 1);
      f[i * 3 + 2] = _at(frame, v + 2);
    }
    morphFrames.add(f);
  }

  return LegacyGeometry(geometry, morphFrames, morphNames);
}

LegacyGeometry decodeLegacyGeometry(String jsonText) =>
    parseLegacyGeometryJson(jsonDecode(jsonText) as Map<String, dynamic>);

List<double> _numList(Object? v) {
  if (v is! List) return const [];
  final out = List<double>.filled(v.length, 0);
  for (var i = 0; i < v.length; i++) {
    final e = v[i];
    out[i] = e is num ? e.toDouble() : 0.0;
  }
  return out;
}

double _at(List<double> l, int i) => i >= 0 && i < l.length ? l[i] : 0.0;
