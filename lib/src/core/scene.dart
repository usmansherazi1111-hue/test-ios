// Scene graph and camera.
//
// Small on purpose: the Jeeliz demos only ever nest a handful of nodes and
// drive them through `position` / `rotation` / `scale`, so this reimplements
// exactly that and nothing else. What it does keep faithfully is the
// *semantics* — parent-relative composition, `renderOrder`, and the
// `setViewOffset` behaviour that JeelizThreeHelper.update_camera depends on to
// letterbox the video into the canvas.

import 'dart:math' as math;

import '../math/vec_mat.dart';
import 'geometry.dart';
import 'material.dart';

class Object3D {
  Object3D({this.name = ''});

  final String name;

  Vec3 position = Vec3.zero;
  Euler rotation = Euler.zero;
  Vec3 scale = Vec3.one;

  bool visible = true;

  /// Lower draws earlier, exactly as in three.js. The face occluder uses -1 so
  /// it lays down depth before anything tries to test against it.
  int renderOrder = 0;

  final List<Object3D> children = [];
  Object3D? parent;

  /// Local -> world. Valid only after [updateMatrixWorld] on the root.
  Mat4 matrixWorld = Mat4.identity();

  /// Replaces the composed `position/rotation/scale` local matrix outright.
  ///
  /// glTF nodes may carry an arbitrary 4x4 that does not decompose cleanly into
  /// a TRS with an Euler rotation, so the loader keeps the matrix rather than
  /// trying. Null everywhere else, where TRS is what the demos actually write.
  Mat4? localMatrixOverride;

  void add(Object3D child) {
    child.parent?.children.remove(child);
    child.parent = this;
    children.add(child);
  }

  void remove(Object3D child) {
    if (children.remove(child)) child.parent = null;
  }

  /// `three.Object3D.scale.multiplyScalar`.
  void scaleUniform(double k) => scale = Vec3(scale.x * k, scale.y * k, scale.z * k);

  void updateMatrixWorld([Mat4? parentWorld]) {
    final local = localMatrixOverride ?? Mat4.compose(position, rotation, scale);
    matrixWorld = parentWorld == null ? local : parentWorld * local;
    for (final c in children) {
      c.updateMatrixWorld(matrixWorld);
    }
  }

  /// Depth-first walk that skips invisible subtrees, matching three's
  /// projectObject: an invisible parent hides its children too.
  void traverseVisible(void Function(Object3D) fn) {
    if (!visible) return;
    fn(this);
    for (final c in children) {
      c.traverseVisible(fn);
    }
  }

  /// Depth-first walk over everything, visible or not — three's `traverse`.
  ///
  /// The tracked face object is invisible until a face is detected, so this is
  /// the one to use for inspecting what a filter built rather than for
  /// deciding what to draw.
  void traverse(void Function(Object3D) fn) {
    fn(this);
    for (final c in children) {
      c.traverse(fn);
    }
  }
}

class Mesh extends Object3D {
  Mesh(this.geometry, Material material, {super.name})
      : materials = [material];

  /// three lets a mesh carry a *list* of materials, one per geometry group.
  /// The tiger head is one mesh with four: whiskers, eyes, face skin and the
  /// inside of the ears.
  Mesh.multiMaterial(this.geometry, this.materials, {super.name})
      : assert(materials.isNotEmpty, 'a mesh needs at least one material');

  BufferGeometry geometry;

  final List<Material> materials;

  /// The single material, for the common case. Reading it on a multi-material
  /// mesh gives the first, which is what three does for sorting purposes too.
  Material get material => materials.first;
  set material(Material m) {
    materials
      ..clear()
      ..add(m);
  }

  /// Per-morph-target weights, parallel to
  /// [BufferGeometry.morphPositions]. three's `Mesh.morphTargetInfluences`.
  ///
  /// The vertex stage applies `position += (frame - position) * influence` for
  /// each non-zero entry, which is three's non-relative morph semantics.
  List<double> morphInfluences = const [];

  bool get hasActiveMorphs =>
      geometry.hasMorphTargets && morphInfluences.isNotEmpty;

  /// Resolves the material a group should draw with, tolerating an index that
  /// runs past the list rather than throwing mid-frame.
  Material materialFor(int index) =>
      materials[index < materials.length ? index : 0];
}

/// A camera-facing quad. three's `THREE.Sprite`: [scale] is its size in world
/// units, and it never rotates with the scene.
class Sprite extends Object3D {
  Sprite(this.material, {super.name});

  Material material;
}

/// three's `AmbientLight`. Adds a flat term to every surface.
class AmbientLight extends Object3D {
  AmbientLight({this.color = const Vec3(1, 1, 1), this.intensity = 1.0});

  Vec3 color;
  double intensity;
}

/// three's `DirectionalLight`. [position] is a *direction* in practice: the
/// light shines from there towards the origin, and only the normalised
/// direction matters.
class DirectionalLight extends Object3D {
  DirectionalLight({
    this.color = const Vec3(1, 1, 1),
    this.intensity = 1.0,
  });

  Vec3 color;
  double intensity;
}

/// three's `PointLight`. Unlike a directional light this has a *position* and
/// falls off with distance, which is what makes the cloud's lightning
/// illuminate only what is near it.
class PointLight extends Object3D {
  PointLight({
    this.color = const Vec3(1, 1, 1),
    this.intensity = 1.0,
    this.distance = 0.0,
    this.decay = 1.0,
  });

  Vec3 color;
  double intensity;

  /// Cutoff distance. Zero means no attenuation at all, which is three's
  /// default and its `PointLight(color, intensity, distance)` third argument.
  double distance;

  /// Falloff exponent. three defaults to 1 outside physically-correct mode.
  double decay;
}

/// The lights gathered for one frame, in view space.
///
/// Both three's Lambert and this renderer fold the `PI` from
/// `getAmbientLightIrradiance` into the `1/PI` of `BRDF_Diffuse_Lambert`, so
/// what a material actually multiplies its diffuse colour by is simply
/// `ambient + Σ saturate(N·L) · lightColor`.
class LightingContext {
  LightingContext(this.ambient, this.directional, [this.point = const []]);

  /// Summed ambient colour × intensity.
  final Vec3 ambient;

  /// Each entry is (direction towards the light in view space, colour ×
  /// intensity).
  final List<({Vec3 direction, Vec3 color})> directional;

  /// Point lights, position already in view space.
  final List<({Vec3 position, Vec3 color, double distance, double decay})> point;

  bool get hasDirect => directional.isNotEmpty || point.isNotEmpty;

  static final empty = LightingContext(Vec3.zero, const []);
}

/// three's `punctualLightIntensityToIrradianceFactor`, outside
/// physically-correct mode:
///
/// ```glsl
/// if (cutoffDistance > 0.0)
///   return pow(saturate(-lightDistance / cutoffDistance + 1.0), decayExponent);
/// return 1.0;
/// ```
double pointLightAttenuation(
    double lightDistance, double cutoffDistance, double decay) {
  if (cutoffDistance <= 0) return 1.0;
  var t = 1.0 - lightDistance / cutoffDistance;
  if (t <= 0) return 0.0;
  if (t > 1) t = 1.0;
  if (decay == 1.0) return t;
  return math.pow(t, decay).toDouble();
}

class Scene extends Object3D {
  Scene() : super(name: 'scene');
}

/// Perspective camera with three's view-offset support.
///
/// `update_camera` in JeelizThreeHelper uses [setViewOffset] to render a
/// centre-crop of the video: the projection is built for the full,
/// uncropped frame and then restricted to the sub-rectangle the canvas
/// actually shows. Without it the filter is subtly mis-scaled whenever the
/// canvas and the camera stream disagree about aspect ratio, which on a phone
/// is essentially always.
class PerspectiveCamera {
  PerspectiveCamera({
    this.fov = 50,
    this.aspect = 1,
    this.near = 0.1,
    this.far = 2000,
  });

  double fov;
  double aspect;
  double near;
  double far;
  double zoom = 1;

  _View? _view;

  /// Cameras in these demos never move, so world->view is the identity. Kept
  /// as a field so a filter that *does* move the camera stays correct.
  Mat4 matrixWorldInverse = Mat4.identity();

  Mat4 projectionMatrix = Mat4.identity();

  void setViewOffset(double fullWidth, double fullHeight, double offsetX,
      double offsetY, double width, double height) {
    _view = _View(fullWidth, fullHeight, offsetX, offsetY, width, height);
  }

  void clearViewOffset() => _view = null;

  void updateProjectionMatrix() {
    var top = near * math.tan(fov * math.pi / 360) / zoom;
    var height = 2 * top;
    var width = aspect * height;
    var left = -0.5 * width;

    final v = _view;
    if (v != null) {
      left += v.offsetX * width / v.fullWidth;
      top -= v.offsetY * height / v.fullHeight;
      width *= v.width / v.fullWidth;
      height *= v.height / v.fullHeight;
    }

    projectionMatrix =
        Mat4.perspective(left, left + width, top, top - height, near, far);
  }
}

class _View {
  const _View(this.fullWidth, this.fullHeight, this.offsetX, this.offsetY,
      this.width, this.height);
  final double fullWidth, fullHeight, offsetX, offsetY, width, height;
}
