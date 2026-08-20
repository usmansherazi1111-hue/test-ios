// The stock three.js materials the demos reach for, minus glassesVTO's two
// (which live in material.dart next to the base contracts).
//
// Note what is *absent*: tone mapping and sRGB encoding. glassesVTO's main.js
// opts into both (`renderer.toneMapping = ACESFilmicToneMapping`,
// `outputEncoding = sRGBEncoding`); the tiger demo's does not, and three r97
// defaults to neither. So these materials write their linear result straight
// out, which is what makes the tiger's flat, saturated look correct rather
// than washed out.

import 'dart:math' as math;
import 'dart:typed_data';

import '../math/vec_mat.dart';
import 'material.dart';
import 'scene.dart' show pointLightAttenuation;
import 'texture.dart';

/// three's `MeshLambertMaterial`.
///
/// One deliberate deviation: three evaluates Lambert **per vertex** and
/// interpolates the result (Gouraud), because that is cheap on a GPU. This
/// evaluates per fragment. On the tiger's 1165-vertex head the difference is a
/// slightly smoother falloff across the muzzle and nothing else; the shading
/// model itself is identical.
///
/// The `PI` in `getAmbientLightIrradiance` cancels the `1/PI` in
/// `BRDF_Diffuse_Lambert`, so this reduces to
/// `diffuse · (ambient + Σ saturate(N·L) · lightColor)`.
class LambertMaterial extends Material {
  LambertMaterial({
    this.color = const Vec3(1, 1, 1),
    this.map,
    this.alphaMap,
    this.opacity = 1.0,
    bool transparent = false,
    MaterialSide side = MaterialSide.front,
    BlendMode blend = BlendMode.normal,
  })  : _transparent = transparent,
        _side = side,
        _blend = blend;

  Vec3 color;
  Texture2D? map;

  /// Opacity from a texture. three's `<alphamap_fragment>` reads the **green**
  /// channel, not alpha — multiLiberty's statue fades out at its edges this
  /// way rather than with a cut-out.
  Texture2D? alphaMap;

  double opacity;

  final bool _transparent;
  final MaterialSide _side;
  final BlendMode _blend;

  @override
  bool get transparent => _transparent;

  @override
  MaterialSide get side => _side;

  @override
  BlendMode get blend => _blend;

  final Float64List _texel = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    var dr = color.x, dg = color.y, db = color.z, da = opacity;

    final m = map;
    if (m != null) {
      m.sample(f.u, f.v, _texel);
      dr *= _texel[0];
      dg *= _texel[1];
      db *= _texel[2];
      da *= _texel[3];
    }

    final am = alphaMap;
    if (am != null) {
      am.sample(f.u, f.v, _texel);
      da *= _texel[1];
    }
    // Bail before lighting, not after. multiLiberty's statue is mostly
    // transparent under `libertyAlphaMapSoft512.png`, and shading a fragment
    // only to throw it away is the single most wasteful thing this material
    // can do — Phong already ordered it this way.
    if (da <= 0.002) return false;

    final lit = lambertIrradiance(f);
    out[0] = dr * lit.x;
    out[1] = dg * lit.y;
    out[2] = db * lit.z;
    out[3] = da;
    return true;
  }
}

/// three's `MeshPhongMaterial`: Lambert diffuse plus a Blinn-Phong specular
/// lobe, with optional diffuse, normal and emissive maps.
///
/// The specular term is three's exactly. Folding out the `PI` that
/// `RE_Direct_BlinnPhong` multiplies in against the `RECIPROCAL_PI` inside
/// `D_BlinnPhong`, one light contributes
///
///     N·L · lightColor · F_Schlick(specular, L·H) · 0.25 · (shininess/2 + 1)
///         · pow(N·H, shininess)
///
/// Defaults match three: white diffuse, `specular` 0x111111, `shininess` 30,
/// and `emissive` **black** — which is worth knowing, because an emissive map
/// multiplies into that black and therefore does nothing until `emissive` is
/// raised. (The casa_de_papel demo ships an emissive map and never raises it.)
class PhongMaterial extends Material {
  PhongMaterial({
    this.color = const Vec3(1, 1, 1),
    this.map,
    this.normalMap,
    this.normalScale = const Vec2(1, 1),
    this.bumpMap,
    this.bumpScale = 1.0,
    this.alphaMap,
    this.emissive = Vec3.zero,
    this.emissiveMap,
    this.specular = const Vec3(0x11 / 255, 0x11 / 255, 0x11 / 255),
    this.shininess = 30.0,
    this.opacity = 1.0,
    bool transparent = false,
    MaterialSide side = MaterialSide.front,
  })  : _transparent = transparent,
        _side = side;

  Vec3 color;
  Texture2D? map;
  Texture2D? normalMap;
  Vec2 normalScale;

  /// A *height* map, perturbed through screen-space derivatives — three's
  /// `bumpMap`, which is a different thing from `normalMap` and reads only the
  /// red channel. Both dog_face meshes use this (passing what is named a normal
  /// map as a bump map, which three happily accepts).
  Texture2D? bumpMap;
  double bumpScale;

  /// Opacity from a texture's green channel. three's `<alphamap_fragment>`
  /// reads `.g`, not `.a`.
  Texture2D? alphaMap;

  Vec3 emissive;
  Texture2D? emissiveMap;
  Vec3 specular;
  double shininess;
  double opacity;

  final bool _transparent;
  final MaterialSide _side;

  @override
  bool get transparent => _transparent;

  @override
  MaterialSide get side => _side;

  @override
  bool get needsTangents => normalMap != null;

  @override
  bool get needsScreenDerivatives => bumpMap != null;

  final Float64List _texel = Float64List(4);
  final Float64List _nrm = Float64List(4);
  final Float64List _emis = Float64List(4);
  final Float64List _bump = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    var dr = color.x, dg = color.y, db = color.z, da = opacity;

    final m = map;
    if (m != null) {
      m.sample(f.u, f.v, _texel);
      dr *= _texel[0];
      dg *= _texel[1];
      db *= _texel[2];
      da *= _texel[3];
    }

    final am = alphaMap;
    if (am != null) {
      am.sample(f.u, f.v, _texel);
      da *= _texel[1]; // three reads the green channel
    }
    if (da <= 0.002) return false;

    // --- shading normal -------------------------------------------------
    var nx = f.nx, ny = f.ny, nz = f.nz;
    final nm = normalMap;
    final bm = bumpMap;
    if (nm != null) {
      nm.sample(f.u, f.v, _nrm);
      final n = f.applyNormalMap(
        (_nrm[0] * 2.0 - 1.0) * normalScale.x,
        (_nrm[1] * 2.0 - 1.0) * normalScale.y,
        _nrm[2] * 2.0 - 1.0,
      );
      nx = n.x;
      ny = n.y;
      nz = n.z;
    } else if (bm != null) {
      final n = _perturbNormalArb(f, bm);
      nx = n.x;
      ny = n.y;
      nz = n.z;
    } else {
      var l = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (l < 1e-12) l = 1;
      nx /= l;
      ny /= l;
      nz /= l;
    }

    // --- lighting -------------------------------------------------------
    final lights = f.lights;
    var lr = lights.ambient.x, lg = lights.ambient.y, lb = lights.ambient.z;
    var sr = 0.0, sg = 0.0, sb = 0.0;

    if (lights.hasDirect) {
      // The eye sits at the origin in view space.
      var vl = math.sqrt(f.vx * f.vx + f.vy * f.vy + f.vz * f.vz);
      if (vl < 1e-12) vl = 1;
      final vdx = -f.vx / vl, vdy = -f.vy / vl, vdz = -f.vz / vl;

      forEachDirectLight(f, (l) {
        final d = l.direction;
        var dotNL = nx * d.x + ny * d.y + nz * d.z;
        if (dotNL <= 0) return;
        if (dotNL > 1) dotNL = 1;

        lr += dotNL * l.color.x;
        lg += dotNL * l.color.y;
        lb += dotNL * l.color.z;

        // Blinn-Phong half vector.
        var hx = d.x + vdx, hy = d.y + vdy, hz = d.z + vdz;
        final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
        if (hl < 1e-12) return;
        hx /= hl;
        hy /= hl;
        hz /= hl;

        final dotNH = clampd(nx * hx + ny * hy + nz * hz, 0, 1);
        final dotLH = clampd(d.x * hx + d.y * hy + d.z * hz, 0, 1);

        // D_BlinnPhong * G_BlinnPhong_Implicit, with the PI cancelled.
        final spec = 0.25 * (0.5 * shininess + 1.0) * _pow(dotNH, shininess);
        if (spec <= 0) return;

        // F_Schlick(specularColor, dotLH)
        final fr = 1.0 - dotLH;
        final f5 = fr * fr * fr * fr * fr;
        final k = dotNL * spec;
        sr += k * l.color.x * (specular.x + (1.0 - specular.x) * f5);
        sg += k * l.color.y * (specular.y + (1.0 - specular.y) * f5);
        sb += k * l.color.z * (specular.z + (1.0 - specular.z) * f5);
      });
    }

    // --- emissive --------------------------------------------------------
    var er = emissive.x, eg = emissive.y, eb = emissive.z;
    if (er > 0 || eg > 0 || eb > 0) {
      // Skipped entirely when emissive is black, which is the default and is
      // why an emissive map alone changes nothing.
      final em = emissiveMap;
      if (em != null) {
        em.sample(f.u, f.v, _emis);
        er *= _emis[0];
        eg *= _emis[1];
        eb *= _emis[2];
      }
    } else {
      er = eg = eb = 0;
    }

    out[0] = dr * lr + sr + er;
    out[1] = dg * lg + sg + eg;
    out[2] = db * lb + sb + eb;
    out[3] = da;
    return true;
  }

  /// three's `dHdxy_fwd()` followed by `perturbNormalArb()`.
  ///
  /// ```glsl
  /// float Hll = bumpScale * texture2D(bumpMap, vUv).x;
  /// float dBx = bumpScale * texture2D(bumpMap, vUv + dFdx(vUv)).x - Hll;
  /// float dBy = bumpScale * texture2D(bumpMap, vUv + dFdy(vUv)).x - Hll;
  /// ...
  /// vec3 R1 = cross(vSigmaY, vN), R2 = cross(vN, vSigmaX);
  /// float fDet = dot(vSigmaX, R1);
  /// vec3 vGrad = sign(fDet) * (dHdxy.x * R1 + dHdxy.y * R2);
  /// return normalize(abs(fDet) * vN - vGrad);
  /// ```
  ///
  /// Reads only the red channel, and takes the height difference one screen
  /// pixel away in each direction — which is why this needs the screen-space
  /// UV derivatives rather than a tangent basis.
  Vec3 _perturbNormalArb(Fragment f, Texture2D bump) {
    bump.sample(f.u, f.v, _bump);
    final hll = bumpScale * _bump[0];
    bump.sample(f.u + f.dudx, f.v + f.dvdx, _bump);
    final dBx = bumpScale * _bump[0] - hll;
    bump.sample(f.u + f.dudy, f.v + f.dvdy, _bump);
    final dBy = bumpScale * _bump[0] - hll;

    var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
    if (nl < 1e-12) nl = 1;
    final vnx = f.nx / nl, vny = f.ny / nl, vnz = f.nz / nl;

    final sxx = f.pdxX, sxy = f.pdxY, sxz = f.pdxZ;
    final syx = f.pdyX, syy = f.pdyY, syz = f.pdyZ;

    // R1 = cross(vSigmaY, vN)
    final r1x = syy * vnz - syz * vny;
    final r1y = syz * vnx - syx * vnz;
    final r1z = syx * vny - syy * vnx;
    // R2 = cross(vN, vSigmaX)
    final r2x = vny * sxz - vnz * sxy;
    final r2y = vnz * sxx - vnx * sxz;
    final r2z = vnx * sxy - vny * sxx;

    final fDet = sxx * r1x + sxy * r1y + sxz * r1z;
    if (fDet.abs() < 1e-20) return Vec3(vnx, vny, vnz);
    final sgn = fDet < 0 ? -1.0 : 1.0;

    final gx = sgn * (dBx * r1x + dBy * r2x);
    final gy = sgn * (dBx * r1y + dBy * r2y);
    final gz = sgn * (dBx * r1z + dBy * r2z);

    final ad = fDet.abs();
    return Vec3(ad * vnx - gx, ad * vny - gy, ad * vnz - gz).normalized;
  }
}

/// Integer-exponent power. Shininess is a small whole number in practice, and
/// this avoids `math.pow`'s log/exp round trip in the fragment loop.
double _pow(double base, double exp) {
  if (base <= 0) return 0;
  var r = 1.0, b = base;
  var e = exp.round();
  if (e < 0) e = 0;
  while (e > 0) {
    if (e & 1 == 1) r *= b;
    b *= b;
    e >>= 1;
  }
  return r;
}

/// three's `MeshBasicMaterial` — unlit, so it ignores the scene's lights
/// entirely. Both luffys_hat demos add an `AmbientLight` that this material
/// makes inert.
class BasicColorMaterial extends Material {
  BasicColorMaterial({
    this.color = const Vec3(1, 1, 1),
    this.map,
    this.opacity = 1.0,
    bool transparent = false,
    MaterialSide side = MaterialSide.front,
    BlendMode blend = BlendMode.normal,
  })  : _transparent = transparent,
        _side = side,
        _blend = blend;

  Vec3 color;

  /// Diffuse map, multiplied into [color] — three's `<map_fragment>`. Null for
  /// the flat-colour case (the cloud's rain, casa's bills).
  Texture2D? map;

  double opacity;

  final bool _transparent;
  final MaterialSide _side;
  final BlendMode _blend;

  @override
  bool get transparent => _transparent;

  @override
  MaterialSide get side => _side;

  @override
  BlendMode get blend => _blend;

  /// Unlit, so the normal is never read — a map does not change that. The
  /// cloud's rain is 1503 of these, and skipping their normal matrices skips
  /// 1503 inverse-3x3 solves per frame.
  @override
  bool get needsNormals => false;

  final Float64List _texel = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    final m = map;
    if (m == null) {
      out[0] = color.x;
      out[1] = color.y;
      out[2] = color.z;
      out[3] = opacity;
      return opacity > 0.002;
    }

    m.sample(f.u, f.v, _texel);
    out[0] = color.x * _texel[0];
    out[1] = color.y * _texel[1];
    out[2] = color.z * _texel[2];
    out[3] = opacity * _texel[3];
    return out[3] > 0.002;
  }
}

/// three's `MeshStandardMaterial` — metallic/roughness PBR, direct lighting
/// only (no env map; `FramesMaterial` covers the image-based case).
///
/// The specular lobe is three r112's `BRDF_Specular_GGX` transcribed:
/// Schlick Fresnel, GGX distribution, and Smith height-correlated visibility.
/// As everywhere else the `PI` from the irradiance term cancels the
/// `RECIPROCAL_PI` inside `D_GGX`, so both are dropped together.
///
/// Defaults are three's: `roughness` **1.0** and `metalness` **0.0**, which
/// matter more than they look — at roughness 1 the highlight is so broad and
/// dim that rupy_helmet's white visor reads as a flat translucent shell, which
/// is exactly what it should look like.
class StandardMaterial extends Material {
  StandardMaterial({
    this.color = const Vec3(1, 1, 1),
    this.map,
    this.mapIsSrgb = false,
    this.normalMap,
    this.normalScale = const Vec2(1, 1),
    this.roughnessMap,
    this.metalnessMap,
    this.aoMap,
    this.aoMapIntensity = 1.0,
    this.emissive = Vec3.zero,
    this.emissiveMap,
    this.emissiveMapIsSrgb = false,
    this.envMap,
    this.envMapIntensity = 1.0,
    this.roughness = 1.0,
    this.metalness = 0.0,
    this.opacity = 1.0,
    bool transparent = false,
    MaterialSide side = MaterialSide.front,
  })  : _transparent = transparent,
        _side = side;

  Vec3 color;
  Texture2D? map;

  /// three's `Texture.encoding = sRGBEncoding`, which GLTFLoader sets on
  /// `map` and `emissiveMap` and on nothing else.
  ///
  /// The shader decodes those to linear. Since neither this demo nor the helper
  /// sets `renderer.outputEncoding`, the linear result is written straight to
  /// the framebuffer — so an sRGB-tagged texture ends up visibly *darker* than
  /// the JPEG it came from. That is what the demo looks like, so it is what
  /// this does.
  bool mapIsSrgb;

  /// Tangent-space normal map. With no TANGENT attribute three derives the
  /// frame from screen-space derivatives (`perturbNormal2Arb`); the per-triangle
  /// tangent this renderer already solves is the same affine gradient.
  Texture2D? normalMap;
  Vec2 normalScale;

  /// three reads roughness from **green** and metalness from **blue**, which is
  /// exactly how glTF packs its single metallicRoughness texture — so both of
  /// these are usually the same object.
  Texture2D? roughnessMap;
  Texture2D? metalnessMap;

  /// Ambient occlusion, read from **red**.
  ///
  /// `<aomap_fragment>` scales indirect diffuse by it, and indirect specular by
  /// `computeSpecularOcclusion`. With a plain cube map there is no indirect
  /// diffuse at all (see [envMap]), so only the specular half is visible here.
  Texture2D? aoMap;
  double aoMapIntensity;

  Vec3 emissive;
  Texture2D? emissiveMap;
  bool emissiveMapIsSrgb;

  /// Image-based lighting from a cube map.
  ///
  /// Only the **specular** half applies. three r112 gates the diffuse term on
  /// `ENVMAP_TYPE_CUBE_UV`, which means a PMREM-processed map; a plain
  /// `CubeTexture` from `CubeTextureLoader` compiles as `ENVMAP_TYPE_CUBE` and
  /// contributes nothing to `iblIrradiance`. Reproducing that is not pedantry:
  /// gltf_fullScreen adds no lights whatsoever, so environment specular is the
  /// *entire* lighting model and adding a diffuse term would wash the helmet
  /// out.
  CubeTexture? envMap;
  double envMapIntensity;

  double roughness;
  double metalness;
  double opacity;

  final bool _transparent;
  final MaterialSide _side;

  @override
  bool get transparent => _transparent;

  @override
  MaterialSide get side => _side;

  @override
  bool get needsTangents => normalMap != null;

  final Float64List _texel = Float64List(4);
  final Float64List _nrm = Float64List(4);
  final Float64List _aux = Float64List(4);
  final Float64List _env = Float64List(3);

  @override
  bool shade(Fragment f, Float64List out) {
    var dr = color.x, dg = color.y, db = color.z, da = opacity;

    final m = map;
    if (m != null) {
      m.sample(f.u, f.v, _texel);
      if (mapIsSrgb) {
        dr *= srgbToLinear(_texel[0]);
        dg *= srgbToLinear(_texel[1]);
        db *= srgbToLinear(_texel[2]);
      } else {
        dr *= _texel[0];
        dg *= _texel[1];
        db *= _texel[2];
      }
      da *= _texel[3];
    }
    if (da <= 0.002) return false;

    // <metalnessmap_fragment> and <roughnessmap_fragment>: green for
    // roughness, blue for metalness.
    //
    // glTF packs both into one texture and GLTFLoader assigns that one object
    // to both slots, so the common case is fetched once and read twice — the
    // same answer for one bilinear fetch instead of two.
    var metalness = this.metalness;
    var roughness = this.roughness;
    final mm = metalnessMap;
    final rm = roughnessMap;
    if (mm != null && identical(mm, rm)) {
      mm.sample(f.u, f.v, _aux);
      metalness *= _aux[2];
      roughness *= _aux[1];
    } else {
      if (mm != null) {
        mm.sample(f.u, f.v, _aux);
        metalness *= _aux[2];
      }
      if (rm != null) {
        rm.sample(f.u, f.v, _aux);
        roughness *= _aux[1];
      }
    }

    // <lights_physical_fragment>
    final oneMinusMetal = 1.0 - metalness;
    final diffR = dr * oneMinusMetal;
    final diffG = dg * oneMinusMetal;
    final diffB = db * oneMinusMetal;

    const kDefaultSpecular = 0.04;
    final specR = kDefaultSpecular * oneMinusMetal + dr * metalness;
    final specG = kDefaultSpecular * oneMinusMetal + dg * metalness;
    final specB = kDefaultSpecular * oneMinusMetal + db * metalness;

    // three clamps roughness to 0.04 in <roughnessmap_fragment>'s consumer,
    // `material.specularRoughness = max( roughnessFactor, 0.0525 )` in later
    // versions and `clamp(roughnessFactor, 0.04, 1.0)` in r112.
    final rough = clampd(roughness, 0.04, 1.0);
    final alpha = rough * rough;
    final a2 = alpha * alpha;

    double nx, ny, nz;
    final nmap = normalMap;
    if (nmap != null) {
      nmap.sample(f.u, f.v, _nrm);
      final n = f.applyNormalMap(
        (_nrm[0] * 2.0 - 1.0) * normalScale.x,
        (_nrm[1] * 2.0 - 1.0) * normalScale.y,
        _nrm[2] * 2.0 - 1.0,
      );
      nx = n.x;
      ny = n.y;
      nz = n.z;
    } else {
      var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
      if (nl < 1e-12) nl = 1;
      nx = f.nx / nl;
      ny = f.ny / nl;
      nz = f.nz / nl;
    }

    final lights = f.lights;
    var r = diffR * lights.ambient.x;
    var g = diffG * lights.ambient.y;
    var b = diffB * lights.ambient.z;

    if (lights.hasDirect) {
      var vl = math.sqrt(f.vx * f.vx + f.vy * f.vy + f.vz * f.vz);
      if (vl < 1e-12) vl = 1;
      final vdx = -f.vx / vl, vdy = -f.vy / vl, vdz = -f.vz / vl;
      final dotNV = clampd(nx * vdx + ny * vdy + nz * vdz, 0, 1);

      forEachDirectLight(f, (l) {
        final d = l.direction;
        final dotNL = clampd(nx * d.x + ny * d.y + nz * d.z, 0, 1);
        if (dotNL <= 0) return;

        // Diffuse.
        r += dotNL * l.color.x * diffR;
        g += dotNL * l.color.y * diffG;
        b += dotNL * l.color.z * diffB;

        // Specular.
        var hx = d.x + vdx, hy = d.y + vdy, hz = d.z + vdz;
        final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
        if (hl < 1e-12) return;
        hx /= hl;
        hy /= hl;
        hz /= hl;

        final dotNH = clampd(nx * hx + ny * hy + nz * hz, 0, 1);
        final dotLH = clampd(d.x * hx + d.y * hy + d.z * hz, 0, 1);

        // D_GGX, minus the RECIPROCAL_PI.
        final denom = dotNH * dotNH * (a2 - 1.0) + 1.0;
        final dTerm = a2 / (denom * denom);

        // V_GGX_SmithCorrelated. At a2 == 1 — three's *default* roughness of
        // 1.0, which is exactly what rupy_helmet's visor uses — both radicands
        // collapse to 1, so the two square roots are provably redundant. Not
        // an approximation: the fully rough branch is algebraically identical.
        final double vis;
        if (a2 >= 1.0) {
          vis = 0.5 / math.max(dotNL + dotNV, 1e-6);
        } else {
          final gv = dotNL * math.sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
          final gl = dotNV * math.sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
          vis = 0.5 / math.max(gv + gl, 1e-6);
        }

        // F_Schlick
        final fr = 1.0 - dotLH;
        final f5 = fr * fr * fr * fr * fr;

        final k = dotNL * vis * dTerm;
        r += k * l.color.x * (specR + (1.0 - specR) * f5);
        g += k * l.color.y * (specG + (1.0 - specG) * f5);
        b += k * l.color.z * (specB + (1.0 - specB) * f5);
      });
    }

    // --- indirect specular, from the cube map ---------------------------
    //
    // `<lights_fragment_maps>`:
    //   radiance += getLightProbeIndirectRadiance(viewDir, normal,
    //                                             specularRoughness, maxMip);
    // then `RE_IndirectSpecular_Physical`:
    //   indirectSpecular += radiance * BRDF_Specular_GGX_Environment(...)
    final env = envMap;
    if (env != null) {
      var vl = math.sqrt(f.vx * f.vx + f.vy * f.vy + f.vz * f.vz);
      if (vl < 1e-12) vl = 1;
      final vdx = -f.vx / vl, vdy = -f.vy / vl, vdz = -f.vz / vl;
      final dotNV = clampd(nx * vdx + ny * vdy + nz * vdz, 0, 1);

      // reflect(-viewDir, normal), then
      // `normalize(mix(reflectVec, normal, roughness*roughness))` — three bends
      // the reflection back towards the normal as the surface roughens, which
      // is a cheap stand-in for the lobe widening.
      final d = 2.0 * (nx * vdx + ny * vdy + nz * vdz);
      var rx = d * nx - vdx;
      var ry = d * ny - vdy;
      var rz = d * nz - vdz;
      final t = rough * rough;
      rx += (nx - rx) * t;
      ry += (ny - ry) * t;
      rz += (nz - rz) * t;
      var rl = math.sqrt(rx * rx + ry * ry + rz * rz);
      if (rl < 1e-12) rl = 1;
      rx /= rl;
      ry /= rl;
      rz /= rl;

      // `inverseTransformDirection(reflectVec, viewMatrix)` — view space back
      // to world. JeelizThreeHelper never moves or rotates its camera, so the
      // view matrix is an identity and this is a no-op. Left as a note rather
      // than dead arithmetic.

      // `queryVec = vec3(flipEnvMap * reflectVec.x, reflectVec.yz)`, and
      // flipEnvMap is **-1** for a CubeTexture: cube maps are specified in a
      // left-handed frame, so three mirrors x on the way in.
      env.sampleDirection(-rx, ry, rz,
          specularMipLevel(rough, env.maxMipLevel), _env);

      // BRDF_Specular_GGX_Environment — Karis's analytic fit to the split-sum
      // environment BRDF, so no lookup table is needed.
      final r0 = rough * -1.0 + 1.0;
      final r1 = rough * -0.0275 + 0.0425;
      final r2 = rough * -0.572 + 1.04;
      final r3 = rough * 0.022 - 0.04;
      final a004 =
          math.min(r0 * r0, _exp2(-9.28 * dotNV)) * r0 + r1;
      final abx = -1.04 * a004 + r2;
      final aby = 1.04 * a004 + r3;

      final kr = _env[0] * envMapIntensity;
      final kg = _env[1] * envMapIntensity;
      final kb = _env[2] * envMapIntensity;

      var sr = specR * abx + aby;
      var sg = specG * abx + aby;
      var sb = specB * abx + aby;

      // <aomap_fragment>: indirect specular is occluded too, through
      // computeSpecularOcclusion.
      final ao = aoMap;
      if (ao != null) {
        ao.sample(f.u, f.v, _aux);
        final occ = (_aux[0] - 1.0) * aoMapIntensity + 1.0;
        final so = clampd(
            math.pow(dotNV + occ, _exp2(-16.0 * rough - 1.0)).toDouble() -
                1.0 +
                occ,
            0,
            1);
        sr *= so;
        sg *= so;
        sb *= so;
      }

      r += kr * sr;
      g += kg * sg;
      b += kb * sb;
    }

    // <emissivemap_fragment> and the final sum.
    var er = emissive.x, eg = emissive.y, eb = emissive.z;
    final em = emissiveMap;
    if (em != null) {
      em.sample(f.u, f.v, _texel);
      if (emissiveMapIsSrgb) {
        er *= srgbToLinear(_texel[0]);
        eg *= srgbToLinear(_texel[1]);
        eb *= srgbToLinear(_texel[2]);
      } else {
        er *= _texel[0];
        eg *= _texel[1];
        eb *= _texel[2];
      }
    }

    out[0] = r + er;
    out[1] = g + eg;
    out[2] = b + eb;
    out[3] = da;
    return true;
  }
}

/// three's `getSpecularMIPLevel`:
///
/// ```glsl
/// float sigma = PI * roughness * roughness / ( 1.0 + roughness );
/// float desiredMIPLevel = maxMIPLevelScalar + log2( sigma );
/// return clamp( desiredMIPLevel, 0.0, maxMIPLevelScalar );
/// ```
///
/// A mirror lands at level 0 and a fully rough surface at the top of the
/// pyramid, which is why the cube map needs mips at all.
double specularMipLevel(double roughness, int maxMipLevel) {
  final sigma = math.pi * roughness * roughness / (1.0 + roughness);
  if (sigma <= 0) return 0;
  final desired = maxMipLevel + math.log(sigma) / math.ln2;
  return clampd(desired, 0, maxMipLevel.toDouble());
}

/// The sRGB electro-optical transfer function, three's `sRGBToLinear`.
double srgbToLinear(double c) => c < 0.04045
    ? c * 0.0773993808
    : math.pow(c * 0.9478672986 + 0.0521327014, 2.4).toDouble();

double _exp2(double x) => math.pow(2.0, x).toDouble();

/// three's `SpriteMaterial`. Always double-sided (a billboard has no back) and
/// never writes depth, so a cloud of them composites in whatever order they
/// come.
class SpriteMaterial extends Material {
  SpriteMaterial({
    required this.map,
    this.color = const Vec3(1, 1, 1),
    this.opacity = 1.0,
    BlendMode blend = BlendMode.additive,
  }) : _blend = blend;

  Texture2D map;
  Vec3 color;
  double opacity;

  final BlendMode _blend;

  @override
  BlendMode get blend => _blend;

  @override
  bool get transparent => true;

  @override
  bool get depthWrite => false;

  @override
  MaterialSide get side => MaterialSide.double;

  final Float64List _texel = Float64List(4);

  @override
  bool shade(Fragment f, Float64List out) {
    map.sample(f.u, f.v, _texel);
    out[0] = _texel[0] * color.x;
    out[1] = _texel[1] * color.y;
    out[2] = _texel[2] * color.z;
    out[3] = _texel[3] * opacity;
    return out[3] > 0.002;
  }
}

/// One incident light at a fragment: unit direction towards it, and its colour
/// already scaled by intensity and distance attenuation.
typedef IncidentLight = ({Vec3 direction, Vec3 color});

/// Walks every direct light — directional and point — reaching a fragment.
///
/// Shared by all three lit materials so they cannot drift apart on what a
/// "light" means. Point lights get three's non-physical falloff, and their
/// direction is recomputed per fragment because it depends on where the
/// fragment is, not just where the light is.
void forEachDirectLight(Fragment f, void Function(IncidentLight) visit) {
  final lights = f.lights;

  for (final l in lights.directional) {
    visit(l);
  }

  for (final l in lights.point) {
    final dx = l.position.x - f.vx;
    final dy = l.position.y - f.vy;
    final dz = l.position.z - f.vz;
    final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (dist < 1e-9) continue;

    final atten = pointLightAttenuation(dist, l.distance, l.decay);
    if (atten <= 0) continue;

    visit((
      direction: Vec3(dx / dist, dy / dist, dz / dist),
      color: Vec3(
          l.color.x * atten, l.color.y * atten, l.color.z * atten),
    ));
  }
}

/// `ambient + Σ saturate(N·L) · lightColor`, in view space.
///
/// Shared by every lit material so they cannot drift apart.
Vec3 lambertIrradiance(Fragment f) {
  final lights = f.lights;
  var r = lights.ambient.x, g = lights.ambient.y, b = lights.ambient.z;

  if (!lights.hasDirect) return Vec3(r, g, b);

  var nl = math.sqrt(f.nx * f.nx + f.ny * f.ny + f.nz * f.nz);
  if (nl < 1e-12) nl = 1;
  final nx = f.nx / nl, ny = f.ny / nl, nz = f.nz / nl;

  forEachDirectLight(f, (l) {
    var d = nx * l.direction.x + ny * l.direction.y + nz * l.direction.z;
    if (d <= 0) return;
    if (d > 1) d = 1;
    r += d * l.color.x;
    g += d * l.color.y;
    b += d * l.color.z;
  });

  return Vec3(r, g, b);
}
