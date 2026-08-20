// Port of demos/threejs/gltf_fullScreen — the Khronos DamagedHelmet, worn.
//
// The demo itself is short: load a glTF, put a cube map on every material,
// centre the model on its bounding box, scale it by width, parent it to the
// face. Almost all the work is in what it *assumes* — a glTF 2.0 reader, a
// mipmapped cube map, and the parts of `MeshStandardMaterial` the earlier
// filters never needed. Those live in core/ (gltf.dart, texture.dart,
// standard_materials.dart); this file is the demo.
//
// The lighting is the surprising part, and it is worth stating plainly:
//
//   * main.js adds **no lights at all** — no ambient, no directional, nothing;
//   * three r112 gates environment *diffuse* on `ENVMAP_TYPE_CUBE_UV`, which
//     means a PMREM-processed map, and `CubeTextureLoader` produces a plain
//     `ENVMAP_TYPE_CUBE`, so `iblIrradiance` is zero;
//   * which leaves environment **specular** as the entire lighting model, plus
//     the emissive map for the glowing vents.
//
// So the helmet is lit only by what it reflects. That reads correctly because
// the model is almost entirely metal, and for metal the specular colour *is*
// the albedo — a dielectric model would come out nearly black. Adding a diffuse
// IBL term "to fix it" would wash the whole thing out.
//
// `followZRot: true` in the init options is satisfied by construction: it asks
// the detector to estimate head roll, and the landmark adapter here always
// solves `rz`.

import 'dart:typed_data';

import '../core/assets.dart';
import '../core/material.dart';
import '../core/gltf.dart';
import '../core/scene.dart';
import '../core/standard_materials.dart';
import '../core/texture.dart';
import '../math/vec_mat.dart';
import '../tracking/face_filter_helper.dart';
import 'filter.dart';

const String _kAssetDir = 'gltfHelmet';

class GltfHelmetFilter extends JeelizFilter {
  GltfHelmetFilter({
    this.textureMaxWidth = 512,
    this.cubeFaceMaxWidth = 128,
  });

  /// The five helmet maps are 2048x2048 JPEGs — 16 MB of RGBA each at full
  /// size, and 80 MB for the set.
  final int textureMaxWidth;

  /// Cube face size. The pyramid adds another third on top of this, six times
  /// over, and the roughest reflections read from the top of it anyway.
  final int cubeFaceMaxWidth;

  /// `SETTINGS.offsetYZ = [0.3, 0]`, applied after centring.
  static const List<double> kOffsetYZ = <double>[0.3, 0];

  /// `SETTINGS.scale = 2.5` — the target *width*, not a multiplier. The model
  /// is scaled by `2.5 / bbox.size.x`.
  static const double kScale = 2.5;

  /// `Bridge2/`, in `CubeTextureLoader`'s order.
  static const List<String> kCubeFaces = <String>[
    'posx.jpg',
    'negx.jpg',
    'posy.jpg',
    'negy.jpg',
    'posz.jpg',
    'negz.jpg',
  ];

  GltfDocument? _document;
  CubeTexture? _envMap;
  final List<Mesh> _meshes = <Mesh>[];
  Object3D? _root;

  /// Model-space bounding box of everything loaded, before centring.
  Vec3 boundsMin = Vec3.zero;
  Vec3 boundsMax = Vec3.zero;

  /// The meshes built from the glTF, for tests.
  List<Mesh> get meshes => List<Mesh>.unmodifiable(_meshes);

  /// The environment cube map, for tests.
  CubeTexture? get envMap => _envMap;

  @override
  Future<void> load() async {
    _document = await parseGltf(
      await loadJeelizAssetString('$_kAssetDir/DamagedHelmet.gltf'),
      (uri) => loadJeelizAssetUint8List('$_kAssetDir/$uri'),
    );

    final faces = <Uint8List>[];
    for (final face in kCubeFaces) {
      faces.add(await loadJeelizAssetUint8List('$_kAssetDir/$face'));
    }
    _envMap = await CubeTexture.decodeFaces(faces, maxWidth: cubeFaceMaxWidth);

    await _loadTextures();
  }

  @override
  void attach(JeelizFaceFilterHelper helper) {
    final doc = _document;
    if (doc == null) return;

    final instances = doc.flatten();
    if (instances.isEmpty) return;

    // `new THREE.Box3().expandByObject(gltf.scene)` — a *world*-space box over
    // the whole scene, so the node's own 90-degree rotation is already in it.
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (final inst in instances) {
      final p = inst.primitive.geometry.positions;
      final m = inst.worldMatrix.m;
      for (var i = 0; i < p.length; i += 3) {
        final x = p[i], y = p[i + 1], z = p[i + 2];
        final wx = m[0] * x + m[4] * y + m[8] * z + m[12];
        final wy = m[1] * x + m[5] * y + m[9] * z + m[13];
        final wz = m[2] * x + m[6] * y + m[10] * z + m[14];
        if (wx < minX) minX = wx;
        if (wy < minY) minY = wy;
        if (wz < minZ) minZ = wz;
        if (wx > maxX) maxX = wx;
        if (wy > maxY) maxY = wy;
        if (wz > maxZ) maxZ = wz;
      }
    }
    boundsMin = Vec3(minX, minY, minZ);
    boundsMax = Vec3(maxX, maxY, maxZ);

    // `gltf.scene.position.add(centre * -1)`, then the offset; and
    // `gltf.scene.scale.multiplyScalar(SETTINGS.scale / sizeX)`.
    //
    // Note the order the demo writes it in: `position` is set from the
    // *unscaled* centre and then `scale` is applied to the same object, so
    // three scales the position too. Reproduced by putting both on one node.
    final centre = Vec3(
      (minX + maxX) * 0.5,
      (minY + maxY) * 0.5,
      (minZ + maxZ) * 0.5,
    );
    final sizeX = maxX - minX;
    final k = sizeX.abs() < 1e-9 ? 1.0 : kScale / sizeX;

    final root = Object3D(name: 'gltfHelmet')
      ..position = Vec3(-centre.x, -centre.y + kOffsetYZ[0],
          -centre.z + kOffsetYZ[1])
      ..scale = Vec3(k, k, k);

    for (final inst in instances) {
      final material = _materialFor(doc, inst.primitive.materialIndex);
      // The node's own transform — here a 90-degree rotation about X, which
      // stands the helmet upright — kept as a matrix rather than decomposed
      // back into an Euler.
      final mesh = Mesh(inst.primitive.geometry, material, name: 'helmetPart')
        ..localMatrixOverride = inst.worldMatrix;
      _meshes.add(mesh);
      root.add(mesh);
    }

    helper.faceObject.add(root);
    _root = root;
  }

  StandardMaterial _materialFor(GltfDocument doc, int? index) {
    // glTF's default material when a primitive names none: white, fully
    // metallic, fully rough.
    final def = index == null
        ? GltfMaterial(name: 'default')
        : doc.materials[index];

    Texture2D? tex(GltfTextureRef? ref) =>
        ref == null ? null : _textures[ref.imageUri];

    // One texture serves as both roughness and metalness, exactly as
    // GLTFLoader assigns it.
    final mr = tex(def.metallicRoughnessTexture);

    return StandardMaterial(
      color: Vec3(def.baseColorFactor[0], def.baseColorFactor[1],
          def.baseColorFactor[2]),
      map: tex(def.baseColorTexture),
      mapIsSrgb: true,
      normalMap: tex(def.normalTexture),
      normalScale: Vec2(def.normalTexture?.scale ?? 1.0,
          def.normalTexture?.scale ?? 1.0),
      roughnessMap: mr,
      metalnessMap: mr,
      aoMap: tex(def.occlusionTexture),
      aoMapIntensity: def.occlusionTexture?.scale ?? 1.0,
      emissive: Vec3(def.emissiveFactor[0], def.emissiveFactor[1],
          def.emissiveFactor[2]),
      emissiveMap: tex(def.emissiveTexture),
      emissiveMapIsSrgb: true,
      envMap: _envMap,
      roughness: def.roughnessFactor,
      metalness: def.metallicFactor,
      opacity: def.baseColorFactor.length > 3 ? def.baseColorFactor[3] : 1.0,
      side: def.doubleSided ? MaterialSide.double : MaterialSide.front,
    );
  }

  /// Decoded images, keyed by the uri the glTF names them with.
  final Map<String, Texture2D> _textures = <String, Texture2D>{};

  /// Decodes every image the document's materials reference.
  Future<void> _loadTextures() async {
    final doc = _document;
    if (doc == null) return;
    final wanted = <String>{};
    for (final m in doc.materials) {
      for (final ref in <GltfTextureRef?>[
        m.baseColorTexture,
        m.metallicRoughnessTexture,
        m.normalTexture,
        m.occlusionTexture,
        m.emissiveTexture,
      ]) {
        if (ref != null) wanted.add(ref.imageUri);
      }
    }
    for (final uri in wanted) {
      _textures[uri] = await Texture2D.decode(
        await loadJeelizAssetUint8List('$_kAssetDir/$uri'),
        maxWidth: textureMaxWidth,
        wrap: TextureWrap.repeat,
      );
    }
  }

  @override
  void detach(JeelizFaceFilterHelper helper) {
    final r = _root;
    if (r != null) helper.faceObject.remove(r);
    _root = null;
    _meshes.clear();
  }
}
