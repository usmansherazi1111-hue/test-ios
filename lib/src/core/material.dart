// Materials — the CPU equivalents of the GLSL the glassesVTO demo runs.
//
// The demo adds **no lights**. Every visible pixel of the frames is a
// reflection of envMap.jpg, weighted by a Fresnel term; every pixel of the
// lenses is that same map multiplied by a blue tint. So these three small
// classes are, between them, the entire look of the filter.
//
// Reference: three.js r112 (what demos/threejs/glassesVTO/index.html loads),
// specifically meshphysical_frag / meshbasic_frag and the chunks they pull in.

import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec_mat.dart';
import 'scene.dart' show LightingContext;
import 'texture.dart';

/// Which faces survive culling. three's `Material.side`.
enum MaterialSide { front, back, double }

/// How a shaded fragment combines with what is already in the framebuffer.
enum BlendMode {
  /// three's `NormalBlending` — src over dst.
  normal,

  /// three's `AdditiveBlending`. The tiger's particles use it so overlapping
  /// sprites build up to a glow instead of occluding each other.
  additive,

  /// three's `CustomBlending` as multiLiberty's face mask configures it:
  ///
  /// ```js
  /// blendSrc: THREE.SrcColorFactor,
  /// blendDst: THREE.OneFactor,
  /// blendEquation: THREE.AddEquation
  /// ```
  ///
  /// The source factor being the *source colour* makes this `dst += src²`, a
  /// quadratic additive tint: bright areas bloom, dark ones all but vanish.
  /// That is what gives the mask its oxidised-bronze glow over the face rather
  /// than a flat wash.
  srcColorAdd,
}

/// Interpolated per-fragment inputs. Reused across fragments — the rasterizer
/// fills it in place rather than allocating, which matters at ~50k
/// invocations per frame.
class Fragment {
  /// View-space shading normal. Not unit length; shaders normalise.
  double nx = 0, ny = 0, nz = 0;

  /// View-space position. The camera sits at the origin looking down -Z, so
  /// this doubles as the (negated) view vector.
  double vx = 0, vy = 0, vz = 0;

  /// Object-space position, *before* any vertex deformation — three's
  /// `position` attribute, which is what the ported shaders read as `vPos`.
  double ox = 0, oy = 0, oz = 0;

  /// Texture coordinates. Zero when the geometry ships no UV attribute.
  double u = 0, v = 0;

  /// Position within the render target, 0..1, origin **top-left**.
  ///
  /// This stands in for `gl_FragCoord.xy / resolution`. The original then maps
  /// it into the video texture with `videoTransformMat2`; here the render
  /// target and the camera frame share an aspect ratio and cover the same
  /// area, so that matrix collapses to identity and this *is* the video UV —
  /// modulo the Y flip, since gl_FragCoord counts from the bottom and a raster
  /// row counts from the top.
  double vpU = 0, vpV = 0;

  /// View-space tangent frame, constant across a triangle and only filled in
  /// when the material sets [Material.needsTangents]. `t` runs along +U, `b`
  /// along +V; together with the shading normal they form the basis a
  /// tangent-space normal map is expressed in.
  double tx = 0, ty = 0, tz = 0;
  double bx = 0, by = 0, bz = 0;

  /// Screen-space derivatives, constant across a triangle and only filled in
  /// when the material sets [Material.needsScreenDerivatives].
  ///
  /// These stand in for GLSL's `dFdx`/`dFdy`. A GPU takes them from
  /// neighbouring fragments in a quad; a rasteriser has no quad, so they are
  /// solved once per triangle from its corners — which is the same affine
  /// gradient, and constant over the triangle either way.
  double dudx = 0, dvdx = 0, dudy = 0, dvdy = 0;
  double pdxX = 0, pdxY = 0, pdxZ = 0;
  double pdyX = 0, pdyY = 0, pdyZ = 0;

  /// Lights for the mesh being drawn. Set once per draw, not per fragment.
  LightingContext lights = LightingContext.empty;

  /// Applies a tangent-space normal-map sample, returning the perturbed
  /// view-space normal. `(mx, my, mz)` is the texel already decoded to -1..1.
  ///
  /// three does this in `perturbNormal2Arb` using screen-space derivatives of
  /// view position and UV. Within a triangle those derivatives describe
  /// exactly the analytic per-triangle tangent frame, which is what the
  /// rasteriser computes instead — same basis, no derivatives required.
  Vec3 applyNormalMap(double mx, double my, double mz) {
    final nxv = tx * mx + bx * my + nx * mz;
    final nyv = ty * mx + by * my + ny * mz;
    final nzv = tz * mx + bz * my + nz * mz;
    return Vec3(nxv, nyv, nzv).normalized;
  }
}

abstract class Material {
  bool get transparent => false;
  bool get colorWrite => true;
  bool get depthWrite => true;
  bool get depthTest => true;
  MaterialSide get side => MaterialSide.front;
  BlendMode get blend => BlendMode.normal;

  /// True when this material rewrites the object-space position in the vertex
  /// stage, as the tiger's mask shader does to swing the lower jaw open.
  ///
  /// three compiles one program per material and draws each geometry group
  /// with its own, so a deformation applies only to the groups using that
  /// material. The renderer reproduces that by running the vertex stage
  /// per group rather than per mesh.
  bool get deformsVertices => false;

  /// False when the material never reads the shading normal, letting the
  /// vertex stage skip the inverse-transpose normal matrix entirely. Unlit
  /// materials say false.
  bool get needsNormals => true;

  /// True when the material reads [Fragment.tx]/[Fragment.bx] — i.e. it has a
  /// normal map. Computing the tangent frame costs a couple of cross products
  /// per triangle, so materials that do not need it do not pay for it.
  bool get needsTangents => false;

  /// True when the material reads the screen-space derivative fields
  /// (`dudx`, `pdx*`, …) — i.e. it has a *bump* map, which three perturbs with
  /// `dFdx`/`dFdy` rather than with a tangent basis.
  bool get needsScreenDerivatives => false;

  /// True when the material computes world position itself instead of letting
  /// the renderer apply `matrixWorld`.
  ///
  /// `FlexMaterial` does: it transforms every vertex by both the current world
  /// matrix and a lagged one and blends the two, which is what makes the dog's
  /// ears flop.
  bool get overridesWorldPosition => false;

  /// Writes the world-space position of an object-space vertex into [out].
  /// Only called when [overridesWorldPosition]. [u]/[v] are that vertex's UVs,
  /// since a material may key the transform off a texture.
  void worldPosition(double x, double y, double z, double u, double v,
      Mat4 model, Float64List out) {
    out[0] = model.m[0] * x + model.m[4] * y + model.m[8] * z + model.m[12];
    out[1] = model.m[1] * x + model.m[5] * y + model.m[9] * z + model.m[13];
    out[2] = model.m[2] * x + model.m[6] * y + model.m[10] * z + model.m[14];
  }

  /// Rewrites `(x, y, z)` into [out]. Only called when [deformsVertices].
  ///
  /// Normals are deliberately left alone: three's `<begin_vertex>` hook edits
  /// `transformed` and never `objectNormal`, so the shading normal of a
  /// swung-open jaw stays where it was. Matching that keeps the port honest.
  void deformVertex(double x, double y, double z, Float64List out) {
    out[0] = x;
    out[1] = y;
    out[2] = z;
  }

  /// Writes display-referred RGBA (0..1, straight alpha, already tone-mapped
  /// and sRGB-encoded) into [out]. Returns false to discard the fragment.
  ///
  /// Tone mapping lives in here rather than in a post pass because that is
  /// where three does it: `<tonemapping_fragment>` and `<encodings_fragment>`
  /// run per-material, so a material that opts out (there are none here, but
  /// still) is genuinely unaffected.
  bool shade(Fragment f, Float64List out);
}

/// Writes depth, never colour. This is the face mesh in front of which the
/// glasses' temples must disappear.
///
/// The original builds it with `colorWrite: false` and `renderOrder = -1` (see
/// `JeelizThreeHelper.create_threejsOccluder`). The fragment shader there
/// returns opaque red purely so the thing is debuggable by flipping one flag —
/// nothing ever samples it.
class OccluderMaterial extends Material {
  @override
  bool get colorWrite => false;

  @override
  bool shade(Fragment f, Float64List out) => false;
}

/// The glasses frames.
///
/// Port of the `ShaderMaterial` in JeelizThreeGlassesCreator: three's standard
/// (physical) shader with two edits — the vertex stage forwards object-space
/// `position.z` as `vPosZ`, and the fragment stage overwrites alpha with
///
/// ```glsl
/// smoothstep(uBranchFading.x - uBranchFading.y*0.5,
///            uBranchFading.x + uBranchFading.y*0.5, vPosZ)
/// ```
///
/// so the temples dissolve where they would otherwise poke out behind the ear.
class FramesMaterial extends Material {
  FramesMaterial({
    required this.envMap,
    this.roughness = 0.0,
    this.metalness = 0.05,
    this.diffuse = const Vec3(1, 1, 1),
    this.envMapIntensity = 1.0,
    this.branchFading = const Vec2(-90, 60),
    this.opacity = 1.0,
    this.decodeEnvMapAsSrgb = false,
  });

  EquirectTexture envMap;
  double roughness;
  double metalness;
  Vec3 diffuse;
  double envMapIntensity;
  double opacity;

  /// `uBranchFading`: x = where the fade sits (more negative pushes it further
  /// back along the temple), y = how abrupt it is.
  final Vec2 branchFading;

  /// The original never sets `texture.encoding`, so three r112 treats the JPEG
  /// as linear and the demo renders brighter than physically correct. Left
  /// false to reproduce that; flip it for a colour-managed result.
  bool decodeEnvMapAsSrgb;

  @override
  bool get transparent => true;

  final Float64List _env = Float64List(3);

  @override
  bool shade(Fragment f, Float64List out) {
    // --- geometry -----------------------------------------------------
    var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
    if (nl < 1e-12) nl = 1;
    final nx = f.nx / nl, ny = f.ny / nl, nz = f.nz / nl;

    // viewDir = normalize(-P_view): fragment -> camera.
    var vl = math.sqrt(f.vx * f.vx + f.vy * f.vy + f.vz * f.vz);
    if (vl < 1e-12) vl = 1;
    final vdx = -f.vx / vl, vdy = -f.vy / vl, vdz = -f.vz / vl;

    // reflect(-viewDir, normal), i.e. the incident ray bounced off the surface.
    final ix = -vdx, iy = -vdy, iz = -vdz;
    final idn = ix * nx + iy * ny + iz * nz;
    var rx = ix - 2 * idn * nx;
    var ry = iy - 2 * idn * ny;
    var rz = iz - 2 * idn * nz;

    // roughness blurs the reflection toward the normal; at roughness 0 this is
    // a no-op, but keeping it makes the knob behave as it does in three.
    final rr = roughness * roughness;
    if (rr > 0) {
      rx += (nx - rx) * rr;
      ry += (ny - ry) * rr;
      rz += (nz - rz) * rr;
    }

    // View space is world space here (the camera never leaves the origin), so
    // inverseTransformDirection is the identity and we can sample directly.
    envMap.sampleDirection(rx, ry, rz, _env);
    var er = _env[0], eg = _env[1], eb = _env[2];
    if (decodeEnvMapAsSrgb) {
      er = _srgbToLinear(er);
      eg = _srgbToLinear(eg);
      eb = _srgbToLinear(eb);
    }
    er *= envMapIntensity;
    eg *= envMapIntensity;
    eb *= envMapIntensity;

    // --- BRDF ---------------------------------------------------------
    // specularColor = mix(vec3(0.04), diffuse, metalness).
    final sc = 0.04 * (1 - metalness);
    final scr = sc + diffuse.x * metalness;
    final scg = sc + diffuse.y * metalness;
    final scb = sc + diffuse.z * metalness;

    // BRDF_Specular_GGX_Environment, the split-sum analytic fit three uses.
    final dotNV = clampd(nx * vdx + ny * vdy + nz * vdz, 0, 1);
    final rough = clampd(roughness, 0.04, 1.0);
    final r0 = rough * -1.0 + 1.0;
    final r1 = rough * -0.0275 + 0.0425;
    final r2 = rough * -0.572 + 1.04;
    final r3 = rough * 0.022 - 0.04;
    final e = math.pow(2.0, -9.28 * dotNV).toDouble();
    final a004 = (r0 * r0 < e ? r0 * r0 : e) * r0 + r1;
    final abx = -1.04 * a004 + r2;
    final aby = 1.04 * a004 + r3;

    // No lights and no light probe in the scene => indirect *diffuse* is zero.
    // The frames really are pure reflection.
    var lr = er * (scr * abx + aby);
    var lg = eg * (scg * abx + aby);
    var lb = eb * (scb * abx + aby);

    // --- output -------------------------------------------------------
    lr = _acesFilmic(lr);
    lg = _acesFilmic(lg);
    lb = _acesFilmic(lb);

    out[0] = _linearToSrgb(lr);
    out[1] = _linearToSrgb(lg);
    out[2] = _linearToSrgb(lb);
    out[3] = opacity *
        smoothstep(branchFading.x - branchFading.y * 0.5,
            branchFading.x + branchFading.y * 0.5, f.oz);
    return out[3] > 0.002;
  }
}

/// The lenses.
///
/// `MeshBasicMaterial({envMap, opacity: 0.7, color: 0x2233aa, transparent})`.
/// With the default `MultiplyOperation` combine and reflectivity 1, three's
/// `<envmap_fragment>` collapses to `outgoing = color * envColor`.
class LensesMaterial extends Material {
  LensesMaterial({
    required this.envMap,
    this.color = const Vec3(0x22 / 255, 0x33 / 255, 0xaa / 255),
    this.opacity = 0.7,
    this.reflectivity = 1.0,
    this.decodeEnvMapAsSrgb = false,
  });

  EquirectTexture envMap;
  Vec3 color;
  double opacity;
  double reflectivity;
  bool decodeEnvMapAsSrgb;

  @override
  bool get transparent => true;

  final Float64List _env = Float64List(3);

  @override
  bool shade(Fragment f, Float64List out) {
    var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
    if (nl < 1e-12) nl = 1;
    final nx = f.nx / nl, ny = f.ny / nl, nz = f.nz / nl;

    // Basic's envmap chunk reflects the camera->fragment ray, not the
    // fragment->camera one, hence no negation here.
    var vl = math.sqrt(f.vx * f.vx + f.vy * f.vy + f.vz * f.vz);
    if (vl < 1e-12) vl = 1;
    final ix = f.vx / vl, iy = f.vy / vl, iz = f.vz / vl;

    final idn = ix * nx + iy * ny + iz * nz;
    final rx = ix - 2 * idn * nx;
    final ry = iy - 2 * idn * ny;
    final rz = iz - 2 * idn * nz;

    envMap.sampleDirection(rx, ry, rz, _env);
    var er = _env[0], eg = _env[1], eb = _env[2];
    if (decodeEnvMapAsSrgb) {
      er = _srgbToLinear(er);
      eg = _srgbToLinear(eg);
      eb = _srgbToLinear(eb);
    }

    // mix(outgoing, outgoing * env, specularStrength * reflectivity)
    final k = clampd(reflectivity, 0, 1);
    var lr = color.x * (1 - k + k * er);
    var lg = color.y * (1 - k + k * eg);
    var lb = color.z * (1 - k + k * eb);

    lr = _acesFilmic(lr);
    lg = _acesFilmic(lg);
    lb = _acesFilmic(lb);

    out[0] = _linearToSrgb(lr);
    out[1] = _linearToSrgb(lg);
    out[2] = _linearToSrgb(lb);
    out[3] = opacity;
    return true;
  }
}

/// three r112's ACESFilmicToneMapping — the Narkowicz approximation. Later
/// three versions swapped in a matrixed version that grades differently, so
/// this is pinned to what the demo actually shipped with.
double _acesFilmic(double c) {
  if (c <= 0) return 0;
  final v = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
  return v < 0 ? 0 : (v > 1 ? 1 : v);
}

double _linearToSrgb(double v) {
  if (v <= 0) return 0;
  if (v >= 1) return 1;
  return v <= 0.0031308 ? v * 12.92 : math.pow(v, 0.41666).toDouble() * 1.055 - 0.055;
}

double _srgbToLinear(double v) {
  if (v <= 0) return 0;
  if (v >= 1) return 1;
  return v < 0.04045 ? v * 0.0773993808 : math.pow(v * 0.9478672986 + 0.0521327014, 2.4).toDouble();
}
