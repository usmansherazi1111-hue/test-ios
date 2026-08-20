// A software rasteriser with a real depth buffer.
//
// Why software, in a framework that has a GPU right there: glassesVTO is not a
// pile of triangles you can paint back-to-front. It needs a depth buffer for
// its own sake — the face occluder is a mesh that writes depth and no colour,
// and that is the only reason the temples vanish behind the head instead of
// being drawn across the cheek. Flutter's public drawing API
// (`Canvas.drawVertices`) has no depth buffer and no fragment stage, and
// `FragmentProgram` gives fragments but no vertex stage. Neither can express a
// depth-only pass, so the depth buffer has to be ours.
//
// The tiger filter then needs the rest of a small forward renderer: UV-mapped
// textures, four materials on one mesh, real lights, additive-blended sprites,
// and a vertex stage a material can hook to swing the jaw open.
//
// The output is a transparent RGBA image that the widget composites over the
// live camera preview, which replaces the full-screen video quad three renders
// underneath the scene.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/geometry.dart';
import '../core/material.dart';
import '../core/scene.dart';
import '../math/vec_mat.dart';

/// Colour + depth target.
///
/// [color] is **premultiplied** RGBA8888, which is both what the "over"
/// operator falls out of naturally and what `ui.decodeImageFromPixels`
/// expects. [depth] holds NDC z in [-1, 1]; nearer is smaller.
class Framebuffer {
  Framebuffer(this.width, this.height)
      : color = Uint8List(width * height * 4),
        depth = Float32List(width * height);

  final int width, height;
  final Uint8List color;
  final Float32List depth;

  void clear() {
    color.fillRange(0, color.length, 0);
    depth.fillRange(0, depth.length, 1.0);
  }

  /// Hands the pixels to the engine. Asynchronous because that is the only
  /// route from raw bytes to a `ui.Image` in Flutter; the caller is already on
  /// an async camera-frame boundary so this costs no extra latency in practice.
  Future<ui.Image> toImage() {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      color,
      width,
      height,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }
}

/// Doubles carried per vertex through clipping:
/// clip.xyzw (4) + viewPos.xyz (3) + viewNormal.xyz (3) + objectPos.xyz (3)
/// + uv (2).
const int _kVaryings = 15;

/// Of those, the ones interpolated perspective-correctly across a triangle
/// (everything after clip.xyzw).
const int _kInterp = 11;

class RenderStats {
  int meshes = 0;
  int triangles = 0;
  int rasterised = 0;
  int fragments = 0;

  @override
  String toString() =>
      'meshes=$meshes tris=$triangles drawn=$rasterised frags=$fragments';
}

class SoftwareRenderer {
  final Fragment _frag = Fragment();
  final Float64List _shadeOut = Float64List(4);
  final Float64List _deformed = Float64List(3);
  final Float64List _worldPos = Float64List(3);

  // Per-vertex scratch, grown on demand and reused every frame.
  Float64List _clip = Float64List(0);
  Float64List _viewPos = Float64List(0);
  Float64List _viewNrm = Float64List(0);

  // Clipping workspace: at most 4 vertices out of a one-plane clip, but the
  // buffers hold a comfortable margin.
  final Float64List _polyA = Float64List(_kVaryings * 8);
  final Float64List _polyB = Float64List(_kVaryings * 8);

  // Projected triangle corners, filled by _projectAndRaster.
  final Float64List _sx = Float64List(3);
  final Float64List _sy = Float64List(3);
  final Float64List _sz = Float64List(3);
  final Float64List _invW = Float64List(3);
  final Float64List _var = Float64List(3 * _kInterp); // varyings * 1/w

  final RenderStats stats = RenderStats();

  void render(Object3D scene, PerspectiveCamera camera, Framebuffer fb) {
    stats
      ..meshes = 0
      ..triangles = 0
      ..rasterised = 0
      ..fragments = 0;

    scene.updateMatrixWorld();
    camera.updateProjectionMatrix();

    final view = camera.matrixWorldInverse;

    // Collect drawables and lights in one walk.
    final items = <_Renderable>[];
    final ambient = <AmbientLight>[];
    final directional = <DirectionalLight>[];
    final point = <PointLight>[];

    scene.traverseVisible((o) {
      if (o is AmbientLight) {
        ambient.add(o);
      } else if (o is DirectionalLight) {
        directional.add(o);
      } else if (o is PointLight) {
        point.add(o);
      } else if (o is Mesh) {
        final mv = view * o.matrixWorld;
        items.add(_Renderable(
            mesh: o, modelView: mv, model: o.matrixWorld, viewZ: mv.m[14]));
      } else if (o is Sprite) {
        final mv = view * o.matrixWorld;
        items.add(_Renderable(
            sprite: o, modelView: mv, model: o.matrixWorld, viewZ: mv.m[14]));
      }
    });

    _frag.lights = _buildLighting(ambient, directional, point, view);

    // Order the way three does, and the nesting matters: WebGLRenderer keeps
    // two lists and draws *all* of the opaque one before *any* of the
    // transparent one, with `renderOrder` sorting only inside each list.
    //
    // So the opaque/transparent split is the primary key, not renderOrder.
    // Getting that backwards mis-orders rupy_helmet, whose transparent face
    // mask carries `renderOrder = -10000` and would otherwise jump ahead of
    // the opaque helmet.
    //
    // Within a list: opaque front-to-back (painterSortStable), transparent
    // back-to-front (reversePainterSortStable).
    //
    // One known simplification: three splits per *group*, so a multi-material
    // mesh can land in both lists. Here the split is per object, using its
    // first material. No ported filter mixes opaque and transparent materials
    // on one mesh, so nothing currently depends on the difference.
    items.sort((a, b) {
      final ta = a.transparent, tb = b.transparent;
      if (ta != tb) return ta ? 1 : -1;
      if (a.renderOrder != b.renderOrder) {
        return a.renderOrder.compareTo(b.renderOrder);
      }
      // View z is negative in front of the camera, so "furthest first" for
      // transparent means ascending, and "nearest first" for opaque means
      // descending.
      if (ta) return a.viewZ.compareTo(b.viewZ);
      return b.viewZ.compareTo(a.viewZ);
    });

    for (final item in items) {
      final mesh = item.mesh;
      if (mesh != null) {
        _drawMesh(mesh, item.model, item.modelView, view, camera, fb);
      } else {
        _drawSprite(item.sprite!, item.modelView, camera, fb);
      }
    }
  }

  LightingContext _buildLighting(
      List<AmbientLight> ambient,
      List<DirectionalLight> directional,
      List<PointLight> point,
      Mat4 view) {
    var ar = 0.0, ag = 0.0, ab = 0.0;
    for (final l in ambient) {
      ar += l.color.x * l.intensity;
      ag += l.color.y * l.intensity;
      ab += l.color.z * l.intensity;
    }

    final dirs = <({Vec3 direction, Vec3 color})>[];
    for (final l in directional) {
      // three points the light from its world position at the origin, then
      // takes that direction into view space.
      final w = l.matrixWorld.m;
      final worldDir = Vec3(w[12], w[13], w[14]);
      final viewDir = view.transformDirection(worldDir).normalized;
      if (viewDir.lengthSq < 1e-12) continue;
      dirs.add((
        direction: viewDir,
        color: Vec3(l.color.x * l.intensity, l.color.y * l.intensity,
            l.color.z * l.intensity),
      ));
    }
    final points =
        <({Vec3 position, Vec3 color, double distance, double decay})>[];
    for (final l in point) {
      if (l.intensity == 0) continue; // an unlit lightning flash costs nothing
      final w = l.matrixWorld.m;
      final worldPos = Vec3(w[12], w[13], w[14]);
      points.add((
        position: view.transformPoint(worldPos),
        color: Vec3(l.color.x * l.intensity, l.color.y * l.intensity,
            l.color.z * l.intensity),
        distance: l.distance,
        decay: l.decay,
      ));
    }

    return LightingContext(Vec3(ar, ag, ab), dirs, points);
  }

  void _drawMesh(Mesh mesh, Mat4 model, Mat4 modelView, Mat4 view,
      PerspectiveCamera camera, Framebuffer fb) {
    final geom = mesh.geometry;
    final n = geom.vertexCount;
    if (n == 0 || geom.triangleCount == 0) return;

    stats.meshes++;
    stats.triangles += geom.triangleCount;

    if (_clip.length < n * 4) {
      _clip = Float64List(n * 4);
      _viewPos = Float64List(n * 3);
      _viewNrm = Float64List(n * 3);
    }

    // three compiles one program per material and issues one draw per group,
    // so a material's vertex stage only ever runs over its own group. Mirror
    // that: transform per group, using that group's material.
    final groups = geom.groups.isEmpty
        ? [GeometryGroup(0, geom.indices.length, 0)]
        : geom.groups;

    for (final g in groups) {
      final mat = mesh.materialFor(g.materialIndex);
      _runVertexStage(mesh, mat, model, modelView, view, camera);

      final idx = geom.indices;
      final end = (g.start + g.count).clamp(0, idx.length);
      for (var t = g.start; t + 2 < end; t += 3) {
        _assembleAndClip(idx[t], idx[t + 1], idx[t + 2], geom, mat, fb);
      }
    }
  }

  void _runVertexStage(Mesh mesh, Material mat, Mat4 model, Mat4 modelView,
      Mat4 view, PerspectiveCamera camera) {
    final geom = mesh.geometry;
    final mvp = camera.projectionMatrix * modelView;
    // The inverse-transpose is a 3x3 solve per mesh per group; an unlit
    // material never looks at the result. The cloud's rain is 1503 such
    // meshes, so this is not a micro-optimisation there.
    final wantsNormals = mat.needsNormals;
    final nm = wantsNormals ? modelView.normalMatrix3 : null;

    final pos = geom.positions;
    final nrm = geom.normals;
    final uvs = geom.uvs;
    final a = modelView.m, p = mvp.m;
    final deforms = mat.deformsVertices;
    final n = geom.vertexCount;

    // FlexMaterial computes world position itself, so its transform has to run
    // in two steps (model, then view) rather than through the fused modelView.
    // Everything else keeps the cheaper fused path.
    final overridesWorld = mat.overridesWorldPosition;
    final vm = view.m;
    final proj = camera.projectionMatrix.m;

    // Morph targets: `transformed += (frame - position) * influence`, three's
    // non-relative semantics. Only a couple of influences are ever non-zero at
    // once, so the zero ones cost a comparison.
    final morphs = mesh.hasActiveMorphs ? geom.morphPositions : null;
    final influences = mesh.morphInfluences;
    final morphCount = morphs == null
        ? 0
        : (influences.length < morphs.length
            ? influences.length
            : morphs.length);

    for (var i = 0; i < n; i++) {
      final i3 = i * 3;
      var x = pos[i3].toDouble();
      var y = pos[i3 + 1].toDouble();
      var z = pos[i3 + 2].toDouble();

      if (morphs != null) {
        for (var k = 0; k < morphCount; k++) {
          final w = influences[k];
          if (w == 0) continue;
          final f = morphs[k];
          x += (f[i3] - pos[i3]) * w;
          y += (f[i3 + 1] - pos[i3 + 1]) * w;
          z += (f[i3 + 2] - pos[i3 + 2]) * w;
        }
      }

      if (deforms) {
        mat.deformVertex(x, y, z, _deformed);
        x = _deformed[0];
        y = _deformed[1];
        z = _deformed[2];
      }

      double vx, vy, vz;
      if (overridesWorld) {
        final u = uvs == null ? 0.0 : uvs[i * 2].toDouble();
        final v = uvs == null ? 0.0 : uvs[i * 2 + 1].toDouble();
        mat.worldPosition(x, y, z, u, v, model, _worldPos);
        final wx = _worldPos[0], wy = _worldPos[1], wz = _worldPos[2];
        vx = vm[0] * wx + vm[4] * wy + vm[8] * wz + vm[12];
        vy = vm[1] * wx + vm[5] * wy + vm[9] * wz + vm[13];
        vz = vm[2] * wx + vm[6] * wy + vm[10] * wz + vm[14];
      } else {
        vx = a[0] * x + a[4] * y + a[8] * z + a[12];
        vy = a[1] * x + a[5] * y + a[9] * z + a[13];
        vz = a[2] * x + a[6] * y + a[10] * z + a[14];
      }

      _viewPos[i3] = vx;
      _viewPos[i3 + 1] = vy;
      _viewPos[i3 + 2] = vz;

      if (nm != null) {
        final nx = nrm[i3].toDouble(),
            ny = nrm[i3 + 1].toDouble(),
            nz = nrm[i3 + 2].toDouble();
        _viewNrm[i3] = nm[0] * nx + nm[1] * ny + nm[2] * nz;
        _viewNrm[i3 + 1] = nm[3] * nx + nm[4] * ny + nm[5] * nz;
        _viewNrm[i3 + 2] = nm[6] * nx + nm[7] * ny + nm[8] * nz;
      } else {
        _viewNrm[i3] = 0;
        _viewNrm[i3 + 1] = 0;
        _viewNrm[i3 + 2] = 1;
      }

      final i4 = i * 4;
      if (overridesWorld) {
        _clip[i4] = proj[0] * vx + proj[4] * vy + proj[8] * vz + proj[12];
        _clip[i4 + 1] = proj[1] * vx + proj[5] * vy + proj[9] * vz + proj[13];
        _clip[i4 + 2] = proj[2] * vx + proj[6] * vy + proj[10] * vz + proj[14];
        _clip[i4 + 3] = proj[3] * vx + proj[7] * vy + proj[11] * vz + proj[15];
      } else {
        _clip[i4] = p[0] * x + p[4] * y + p[8] * z + p[12];
        _clip[i4 + 1] = p[1] * x + p[5] * y + p[9] * z + p[13];
        _clip[i4 + 2] = p[2] * x + p[6] * y + p[10] * z + p[14];
        _clip[i4 + 3] = p[3] * x + p[7] * y + p[11] * z + p[15];
      }
    }
  }

  /// Billboard: a camera-facing quad whose size comes from the world scale.
  void _drawSprite(
      Sprite sprite, Mat4 modelView, PerspectiveCamera camera, Framebuffer fb) {
    final m = modelView.m;
    final cx = m[12], cy = m[13], cz = m[14];

    // Scale is the length of the basis vectors, so a scaled parent still
    // sizes its sprites — which is how the tiger's particles inherit the head.
    final hw = 0.5 *
        Vec3(m[0], m[1], m[2]).length;
    final hh = 0.5 *
        Vec3(m[4], m[5], m[6]).length;
    if (hw <= 0 || hh <= 0) return;

    stats.meshes++;
    stats.triangles += 2;

    final p = camera.projectionMatrix.m;
    final poly = _polyA;

    void corner(int slot, double ox, double oy, double u, double v) {
      final vx = cx + ox * hw, vy = cy + oy * hh, vz = cz;
      final o = slot * _kVaryings;
      poly[o] = p[0] * vx + p[4] * vy + p[8] * vz + p[12];
      poly[o + 1] = p[1] * vx + p[5] * vy + p[9] * vz + p[13];
      poly[o + 2] = p[2] * vx + p[6] * vy + p[10] * vz + p[14];
      poly[o + 3] = p[3] * vx + p[7] * vy + p[11] * vz + p[15];
      poly[o + 4] = vx;
      poly[o + 5] = vy;
      poly[o + 6] = vz;
      // Facing the camera, so the normal is straight back down +Z in view.
      poly[o + 7] = 0;
      poly[o + 8] = 0;
      poly[o + 9] = 1;
      poly[o + 10] = ox;
      poly[o + 11] = oy;
      poly[o + 12] = 0;
      poly[o + 13] = u;
      poly[o + 14] = v;
    }

    final mat = sprite.material;

    corner(0, -1, -1, 0, 0);
    corner(1, 1, -1, 1, 0);
    corner(2, 1, 1, 1, 1);
    _projectAndRaster(poly, 0, _kVaryings, 2 * _kVaryings, mat, fb);

    corner(0, -1, -1, 0, 0);
    corner(1, 1, 1, 1, 1);
    corner(2, -1, 1, 0, 1);
    _projectAndRaster(poly, 0, _kVaryings, 2 * _kVaryings, mat, fb);
  }

  /// Per-triangle tangent basis in view space, from the corners' positions and
  /// UVs.
  ///
  /// three derives this per fragment in `perturbNormal2Arb`:
  ///
  /// ```glsl
  /// vec3 q0 = dFdx(eye_pos), q1 = dFdy(eye_pos);
  /// vec2 st0 = dFdx(vUv),    st1 = dFdy(vUv);
  /// float scale = sign(st1.t * st0.s - st0.t * st1.s);
  /// vec3 S = normalize((q0 * st1.t - q1 * st0.t) * scale);
  /// vec3 T = normalize((-q0 * st1.s + q1 * st0.s) * scale);
  /// ```
  ///
  /// Those derivatives are, within one triangle, exactly this basis — so
  /// solving it directly from the three corners gives the same frame without
  /// needing screen-space derivatives the rasteriser does not have. The
  /// `sign(det)` term is kept: it is what keeps mirrored UV islands from
  /// lighting inside-out.
  void _computeTangentFrame(Float64List poly, int o0, int o1, int o2) {
    final p0x = poly[o0 + 4], p0y = poly[o0 + 5], p0z = poly[o0 + 6];
    final e1x = poly[o1 + 4] - p0x,
        e1y = poly[o1 + 5] - p0y,
        e1z = poly[o1 + 6] - p0z;
    final e2x = poly[o2 + 4] - p0x,
        e2y = poly[o2 + 5] - p0y,
        e2z = poly[o2 + 6] - p0z;

    final u0 = poly[o0 + 13], v0 = poly[o0 + 14];
    final d1u = poly[o1 + 13] - u0, d1v = poly[o1 + 14] - v0;
    final d2u = poly[o2 + 13] - u0, d2v = poly[o2 + 14] - v0;

    final det = d1u * d2v - d2u * d1v;
    if (det.abs() < 1e-20) {
      // Degenerate UVs: fall back to any frame orthogonal to the normal so
      // the map at least does not produce NaNs.
      _frag
        ..tx = 1
        ..ty = 0
        ..tz = 0
        ..bx = 0
        ..by = 1
        ..bz = 0;
      return;
    }
    final s = det < 0 ? -1.0 : 1.0;

    var tX = (e1x * d2v - e2x * d1v) * s;
    var tY = (e1y * d2v - e2y * d1v) * s;
    var tZ = (e1z * d2v - e2z * d1v) * s;
    var bX = (e2x * d1u - e1x * d2u) * s;
    var bY = (e2y * d1u - e1y * d2u) * s;
    var bZ = (e2z * d1u - e1z * d2u) * s;

    var tl = math.sqrt(tX * tX + tY * tY + tZ * tZ);
    if (tl < 1e-20) tl = 1;
    var bl = math.sqrt(bX * bX + bY * bY + bZ * bZ);
    if (bl < 1e-20) bl = 1;

    tX /= tl;
    tY /= tl;
    tZ /= tl;
    bX /= bl;
    bY /= bl;
    bZ /= bl;

    _frag
      ..tx = tX
      ..ty = tY
      ..tz = tZ
      ..bx = bX
      ..by = bY
      ..bz = bZ;
  }

  /// Per-triangle screen-space derivatives of UV and view position — the
  /// `dFdx`/`dFdy` a bump map needs.
  ///
  /// For an attribute `a` sampled at the three corners, the affine gradient in
  /// screen space is
  ///
  ///     da/dx = [(a1-a0)(y2-y0) - (a2-a0)(y1-y0)] / area
  ///     da/dy = [(a2-a0)(x1-x0) - (a1-a0)(x2-x0)] / area
  ///
  /// with `area` the same signed area the barycentrics use. A GPU differences
  /// neighbouring fragments in a 2x2 quad, which for a linearly-interpolated
  /// attribute gives this; a rasteriser has no quad, so it solves it directly
  /// and gets one value for the whole triangle.
  void _computeScreenDerivatives(
      Float64List poly, int o0, int o1, int o2, double area) {
    if (area.abs() < 1e-20) return;
    final inv = 1.0 / area;

    final y10 = _sy[1] - _sy[0], y20 = _sy[2] - _sy[0];
    final x10 = _sx[1] - _sx[0], x20 = _sx[2] - _sx[0];

    // Note the *screen* Y axis points down while these offsets came from the
    // projected corners, so the sign convention matches the barycentrics and
    // stays self-consistent with `area`.
    double ddx(double a0, double a1, double a2) =>
        ((a1 - a0) * y20 - (a2 - a0) * y10) * inv;
    double ddy(double a0, double a1, double a2) =>
        ((a2 - a0) * x10 - (a1 - a0) * x20) * inv;

    final u0 = poly[o0 + 13], u1 = poly[o1 + 13], u2 = poly[o2 + 13];
    final v0 = poly[o0 + 14], v1 = poly[o1 + 14], v2 = poly[o2 + 14];

    _frag
      ..dudx = ddx(u0, u1, u2)
      ..dvdx = ddx(v0, v1, v2)
      ..dudy = ddy(u0, u1, u2)
      ..dvdy = ddy(v0, v1, v2)
      ..pdxX = ddx(poly[o0 + 4], poly[o1 + 4], poly[o2 + 4])
      ..pdxY = ddx(poly[o0 + 5], poly[o1 + 5], poly[o2 + 5])
      ..pdxZ = ddx(poly[o0 + 6], poly[o1 + 6], poly[o2 + 6])
      ..pdyX = ddy(poly[o0 + 4], poly[o1 + 4], poly[o2 + 4])
      ..pdyY = ddy(poly[o0 + 5], poly[o1 + 5], poly[o2 + 5])
      ..pdyZ = ddy(poly[o0 + 6], poly[o1 + 6], poly[o2 + 6]);
  }

  /// Packs three indexed vertices into the clip polygon, clips against the
  /// near plane, and fans the result out to the rasteriser.
  void _assembleAndClip(int ia, int ib, int ic, BufferGeometry geom,
      Material mat, Framebuffer fb) {
    final poly = _polyA;
    _packVertex(poly, 0, ia, geom);
    _packVertex(poly, _kVaryings, ib, geom);
    _packVertex(poly, 2 * _kVaryings, ic, geom);

    // Fast path: wholly in front of the near plane, which is the overwhelming
    // majority of triangles.
    var allIn = true;
    for (var i = 0; i < 3; i++) {
      final o = i * _kVaryings;
      if (poly[o + 2] + poly[o + 3] < 0) {
        allIn = false;
        break;
      }
    }

    if (allIn) {
      _projectAndRaster(poly, 0, _kVaryings, 2 * _kVaryings, mat, fb);
      return;
    }

    final clipped = _clipNear(poly, 3, _polyB);
    if (clipped < 3) return;
    for (var i = 1; i + 1 < clipped; i++) {
      _projectAndRaster(
          _polyB, 0, i * _kVaryings, (i + 1) * _kVaryings, mat, fb);
    }
  }

  void _packVertex(Float64List poly, int o, int vi, BufferGeometry geom) {
    final i4 = vi * 4, i3 = vi * 3;
    poly[o] = _clip[i4];
    poly[o + 1] = _clip[i4 + 1];
    poly[o + 2] = _clip[i4 + 2];
    poly[o + 3] = _clip[i4 + 3];
    poly[o + 4] = _viewPos[i3];
    poly[o + 5] = _viewPos[i3 + 1];
    poly[o + 6] = _viewPos[i3 + 2];
    poly[o + 7] = _viewNrm[i3];
    poly[o + 8] = _viewNrm[i3 + 1];
    poly[o + 9] = _viewNrm[i3 + 2];
    // Object-space position is the *undeformed* attribute, matching the
    // `vPos = position` the ported shaders read.
    poly[o + 10] = geom.positions[i3].toDouble();
    poly[o + 11] = geom.positions[i3 + 1].toDouble();
    poly[o + 12] = geom.positions[i3 + 2].toDouble();

    final uv = geom.uvs;
    if (uv != null) {
      final i2 = vi * 2;
      poly[o + 13] = uv[i2].toDouble();
      poly[o + 14] = uv[i2 + 1].toDouble();
    } else {
      poly[o + 13] = 0;
      poly[o + 14] = 0;
    }
  }

  /// Sutherland–Hodgman against `z + w >= 0` (the OpenGL near plane).
  /// Returns the vertex count written into [dst].
  int _clipNear(Float64List src, int count, Float64List dst) {
    var out = 0;
    for (var i = 0; i < count; i++) {
      final ci = i * _kVaryings;
      final cj = ((i + 1) % count) * _kVaryings;
      final di = src[ci + 2] + src[ci + 3];
      final dj = src[cj + 2] + src[cj + 3];
      final insideI = di >= 0, insideJ = dj >= 0;

      if (insideI) {
        final o = out * _kVaryings;
        for (var k = 0; k < _kVaryings; k++) {
          dst[o + k] = src[ci + k];
        }
        out++;
      }
      if (insideI != insideJ) {
        final t = di / (di - dj);
        final o = out * _kVaryings;
        for (var k = 0; k < _kVaryings; k++) {
          dst[o + k] = src[ci + k] + (src[cj + k] - src[ci + k]) * t;
        }
        out++;
        if (out >= 8) break;
      }
    }
    return out;
  }

  void _projectAndRaster(Float64List poly, int o0, int o1, int o2, Material mat,
      Framebuffer fb) {
    final w = fb.width, h = fb.height;

    for (var i = 0; i < 3; i++) {
      final o = i == 0 ? o0 : (i == 1 ? o1 : o2);
      final cw = poly[o + 3];
      if (cw.abs() < 1e-12) return;
      final iw = 1.0 / cw;
      _invW[i] = iw;
      _sx[i] = (poly[o] * iw * 0.5 + 0.5) * w;
      // NDC +Y is up, raster +Y is down.
      _sy[i] = (0.5 - poly[o + 1] * iw * 0.5) * h;
      _sz[i] = poly[o + 2] * iw;
      // Varyings are interpolated in screen space only after division by w.
      final v = i * _kInterp;
      for (var k = 0; k < _kInterp; k++) {
        _var[v + k] = poly[o + 4 + k] * iw;
      }
    }

    final area = (_sx[1] - _sx[0]) * (_sy[2] - _sy[0]) -
        (_sx[2] - _sx[0]) * (_sy[1] - _sy[0]);
    if (area == 0 || !area.isFinite) return;

    // A counter-clockwise triangle in NDC lands clockwise once Y is flipped,
    // which makes the signed screen area negative for a front face.
    final frontFacing = area < 0;
    switch (mat.side) {
      case MaterialSide.front:
        if (!frontFacing) return;
      case MaterialSide.back:
        if (frontFacing) return;
      case MaterialSide.double:
        break;
    }
    // three flips the shading normal for double-sided back faces.
    final normalSign =
        (mat.side == MaterialSide.double && !frontFacing) ? -1.0 : 1.0;

    var minX = _sx[0], maxX = _sx[0], minY = _sy[0], maxY = _sy[0];
    for (var i = 1; i < 3; i++) {
      if (_sx[i] < minX) minX = _sx[i];
      if (_sx[i] > maxX) maxX = _sx[i];
      if (_sy[i] < minY) minY = _sy[i];
      if (_sy[i] > maxY) maxY = _sy[i];
    }
    var x0 = minX.floor(), x1 = maxX.ceil();
    var y0 = minY.floor(), y1 = maxY.ceil();
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > w - 1) x1 = w - 1;
    if (y1 > h - 1) y1 = h - 1;
    if (x0 > x1 || y0 > y1) return;

    stats.rasterised++;

    if (mat.needsTangents) {
      _computeTangentFrame(poly, o0, o1, o2);
    }
    if (mat.needsScreenDerivatives) {
      _computeScreenDerivatives(poly, o0, o1, o2, area);
    }

    final invArea = 1.0 / area;
    final ax = _sx[0], ay = _sy[0];
    final bx = _sx[1], by = _sy[1];
    final cx = _sx[2], cy = _sy[2];

    final colorWrite = mat.colorWrite;
    final depthWrite = mat.depthWrite;
    final depthTest = mat.depthTest;
    final blend = mat.blend;
    final additive = blend == BlendMode.additive;
    final srcColorAdd = blend == BlendMode.srcColorAdd;

    final color = fb.color;
    final depth = fb.depth;
    final invW = 1.0 / w, invH = 1.0 / h;

    for (var py = y0; py <= y1; py++) {
      final fy = py + 0.5;
      final rowBase = py * w;
      for (var px = x0; px <= x1; px++) {
        final fx = px + 0.5;

        // Edge functions, normalised into barycentrics.
        final l0 = ((bx - ax) * (fy - ay) - (by - ay) * (fx - ax)) * invArea;
        if (l0 < 0) continue;
        final l1 = ((cx - bx) * (fy - by) - (cy - by) * (fx - bx)) * invArea;
        if (l1 < 0) continue;
        final l2 = 1.0 - l0 - l1;
        if (l2 < 0) continue;

        // l0 opposes vertex 2, l1 opposes vertex 0, l2 opposes vertex 1.
        final wA = l1, wB = l2, wC = l0;

        final z = _sz[0] * wA + _sz[1] * wB + _sz[2] * wC;
        final di = rowBase + px;
        if (depthTest && z > depth[di]) continue;

        if (!colorWrite) {
          if (depthWrite) depth[di] = z;
          continue;
        }

        final iw = _invW[0] * wA + _invW[1] * wB + _invW[2] * wC;
        if (iw.abs() < 1e-18) continue;
        final pc = 1.0 / iw;

        const b0 = 0, b1 = _kInterp, b2 = 2 * _kInterp;
        _frag
          ..vx = (_var[b0] * wA + _var[b1] * wB + _var[b2] * wC) * pc
          ..vy = (_var[b0 + 1] * wA + _var[b1 + 1] * wB + _var[b2 + 1] * wC) * pc
          ..vz = (_var[b0 + 2] * wA + _var[b1 + 2] * wB + _var[b2 + 2] * wC) * pc
          ..nx = (_var[b0 + 3] * wA + _var[b1 + 3] * wB + _var[b2 + 3] * wC) *
              pc *
              normalSign
          ..ny = (_var[b0 + 4] * wA + _var[b1 + 4] * wB + _var[b2 + 4] * wC) *
              pc *
              normalSign
          ..nz = (_var[b0 + 5] * wA + _var[b1 + 5] * wB + _var[b2 + 5] * wC) *
              pc *
              normalSign
          ..ox = (_var[b0 + 6] * wA + _var[b1 + 6] * wB + _var[b2 + 6] * wC) * pc
          ..oy = (_var[b0 + 7] * wA + _var[b1 + 7] * wB + _var[b2 + 7] * wC) * pc
          ..oz = (_var[b0 + 8] * wA + _var[b1 + 8] * wB + _var[b2 + 8] * wC) * pc
          ..u = (_var[b0 + 9] * wA + _var[b1 + 9] * wB + _var[b2 + 9] * wC) * pc
          ..v = (_var[b0 + 10] * wA + _var[b1 + 10] * wB + _var[b2 + 10] * wC) *
              pc
          ..vpU = (px + 0.5) * invW
          ..vpV = (py + 0.5) * invH;

        if (!mat.shade(_frag, _shadeOut)) continue;
        stats.fragments++;

        final sa =
            _shadeOut[3] < 0 ? 0.0 : (_shadeOut[3] > 1 ? 1.0 : _shadeOut[3]);
        final ci = di * 4;

        if (additive) {
          // dst += src * srcAlpha, with alpha saturating so the overlay stays
          // opaque enough to be seen over the camera preview.
          color[ci] = _byte(_shadeOut[0] * sa * 255 + color[ci]);
          color[ci + 1] = _byte(_shadeOut[1] * sa * 255 + color[ci + 1]);
          color[ci + 2] = _byte(_shadeOut[2] * sa * 255 + color[ci + 2]);
          color[ci + 3] = _byte(sa * 255 + color[ci + 3]);
        } else if (srcColorAdd) {
          // dst += src * src. The source factor is the source colour itself,
          // so the contribution is squared before being added.
          color[ci] = _byte(_shadeOut[0] * _shadeOut[0] * 255 + color[ci]);
          color[ci + 1] =
              _byte(_shadeOut[1] * _shadeOut[1] * 255 + color[ci + 1]);
          color[ci + 2] =
              _byte(_shadeOut[2] * _shadeOut[2] * 255 + color[ci + 2]);
          color[ci + 3] = _byte(sa * 255 + color[ci + 3]);
        } else if (sa >= 0.999) {
          color[ci] = _byte(_shadeOut[0] * 255);
          color[ci + 1] = _byte(_shadeOut[1] * 255);
          color[ci + 2] = _byte(_shadeOut[2] * 255);
          color[ci + 3] = 255;
        } else {
          // Premultiplied "over": dst = src*a + dst*(1-a).
          final inv = 1.0 - sa;
          color[ci] = _byte(_shadeOut[0] * sa * 255 + color[ci] * inv);
          color[ci + 1] = _byte(_shadeOut[1] * sa * 255 + color[ci + 1] * inv);
          color[ci + 2] = _byte(_shadeOut[2] * sa * 255 + color[ci + 2] * inv);
          color[ci + 3] = _byte(sa * 255 + color[ci + 3] * inv);
        }

        if (depthWrite) depth[di] = z;
      }
    }
  }
}

/// Rounds and saturates to a byte. Uint8List assignment masks rather than
/// clamps, so an unsaturated highlight would wrap to black without this.
int _byte(double v) {
  if (!(v > 0)) return 0; // also catches NaN
  if (v >= 255) return 255;
  return v.round();
}

class _Renderable {
  _Renderable({
    this.mesh,
    this.sprite,
    required this.modelView,
    required this.model,
    required this.viewZ,
  });

  final Mesh? mesh;
  final Sprite? sprite;
  final Mat4 modelView;

  /// Local -> world, kept separately because a material that overrides world
  /// position needs the two steps split apart.
  final Mat4 model;
  final double viewZ;

  int get renderOrder => mesh?.renderOrder ?? sprite!.renderOrder;

  bool get transparent =>
      mesh?.material.transparent ?? sprite!.material.transparent;
}
