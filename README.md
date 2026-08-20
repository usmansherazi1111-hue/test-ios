# jeeliz_dart

Pure Dart/Flutter port of the [Jeeliz FaceFilter](https://github.com/jeeliz/jeelizFaceFilter)
demos. No JavaScript, no WebView, no `three.js`, no `dart:js_interop` — the
scene graph, the pose maths, the materials and the rasteriser are all Dart.

**Ported so far: `glassesVTO`, `tiger`, `casa_de_papel`, `rupy_helmet`,
`dog_face`, `cloud`, `multiLiberty`, `CSS3D/comedy-glasses`,
`faceReplacement/image`, `celFace`, `butterflies`, `matrix`,
`luffys_hat` (both parts), `gltf_fullScreen`, `fireworks`, `halloween_spider`.**

All 3D assets are the demos' own, copied unchanged.

| Filter | Needs | Notes |
| --- | --- | --- |
| **glassesVTO** | depth-only occluder, env-map IBL | No lights at all — the frames are pure Fresnel-weighted reflection. |
| **tiger** | UV textures, 4 materials on one mesh, real lights, a vertex deformation, camera-video sampling, additive sprites | The eye "holes" are not transparency; they are camera video the mask paints itself. |
| **casa_de_papel** | Phong + tangent-space normal mapping, world-space animated meshes, a full-screen foreground | Its `emissiveMap` and `reflectivity` are both inert in the original — see below. |
| **rupy_helmet** | GGX standard material, **colour** camera video, opaque-before-transparent ordering | The face isn't hidden by the helmet — a mesh redraws the video darkened, so you look like you're in shadow inside it. |
| **dog_face** | legacy `Geometry` JSON, morph-target animation, bump mapping, `FlexMaterial` | The ears flop because every vertex is placed by *two* matrices — the real one and a lagged one — blended by a painted map. |
| **cloud** | point lights with distance falloff, 1503 animated meshes | A rain cloud over the head, with lightning that double-flickers rather than flashing once. |
| **multiLiberty** | **multi-face tracking**, depth-sorted faces, a custom blend equation | Four statues at once. The model's face sits at its origin, so you end up standing *inside* a five-metre Liberty. |
| **comedy-glasses** | *no renderer at all* — a tracked `Transform` | The CSS3D path: a flat sprite placed by a matrix, composited by the GPU. Cheapest and sharpest filter here. |
| **faceReplacement/image** | *no renderer at all* — 2D compositing, HSV colour matching, a face detector run on a still image | Your face inside a painting. The only filter that replaces the camera preview rather than drawing over it. |
| **celFace** | a render-to-texture *chain*: toon pass, two separable blurs, composite | A mesh used as a stencil, not a surface. Its normals are computed and never read, and its four-colour palette is thrown away by the last pass. |
| **butterflies** | 106-frame morph animation, nine instances of one geometry, nine point lights and no other light at all | Nine butterflies, not the ten the constant says. Their point lights *are* the lighting model, so a butterfly at the bottom of its tween goes black rather than invisible. |
| **matrix** | a screen-space refraction, a green camera key, and a background that is **not** the camera | The one filter that replaces the preview instead of drawing over it. Its mask has no visible edge: at the silhouette it resolves to exactly the background behind it. |
| **luffys_hat** (parts 1 and 2) | a textured unlit mesh; then rupy_helmet's face shader again, a moved tracking pivot, and a frame | Two demos, one hat, and part 2 is part 1 done properly. Part 1 has three lines that do nothing — including a rotation of -40 *radians*. |
| **gltf_fullScreen** | a **glTF 2.0 reader**, a mipmapped cube map, and the rest of `MeshStandardMaterial` | The Khronos DamagedHelmet. It has no lights at all: environment *specular* is the entire lighting model, and that only works because the model is metal. |
| **fireworks** | 1,020 additive sprites, a procedurally painted gradient, and tweens | Nothing new to build, and almost every number in it is off by something. Its burst angle is the *logarithm* of an angle. |
| **halloween_spider** | two 121-frame morph animations, played **once** on a mouth trigger | The first filter that waits for you. Four of its parts are dead, including a whole texture and both of its lights. |

## Running the demo

This directory is also a runnable Flutter app. Plug in a phone and:

```bash
flutter run
```

`lib/main.dart` runs the ported filters on the front camera, with a filter
switch, a render-resolution slider and a tracking HUD. On casa_de_papel,
rupy_helmet and dog_face — the three whose originals call
`addDragEventListener` — you can drag to nudge the model onto your face, and
double-tap to re-centre. casa_de_papel also gets a **Bella Ciao** button to
start the money falling, and dog_face unrolls its tongue when you open your
mouth. Selecting **Liberty** restarts the camera in multi-face mode — it tracks
four faces at once, so get a friend in frame. **Comedy** takes the CSS3D path —
no rasteriser at all, so the render slider and the HUD do not apply to it.
**Painting** hides the camera entirely and shows you inside one of ten
paintings and film posters; the arrows cycle through them. **Cel** gets a
sharper camera texture than the rest (320 rather than 192) because its edge
detector reaches exactly one video texel. **Wings** takes about six seconds to
fill up — the butterflies arrive one at a time, 600 ms apart, exactly as the
demo's `setTimeout(..., 600*i)` chain does. **Matrix** covers the camera
preview completely; the camera is still running, but only as an input to the
shader. **Luffy 1** and **Luffy 2** are the same hat before and after the demo
author finished it; only Luffy 2 is draggable.

The camera capture it uses lives in `lib/demo/` and is **not** part of the
library — nothing under `lib/src/` imports a camera or ML plugin, which is what
keeps the port drivable by any tracker. `camera` and `mediapipe_face_mesh` are
dependencies of this directory only because the demo needs them.

> If you re-run `flutter create .` here, it will overwrite `lib/main.dart` with
> the counter template. That template uses dot-shorthand syntax
> (`colorScheme: .fromSeed(...)`), which needs `sdk: '>=3.10.0'`; against this
> package's `>=3.0.0` constraint it fails to compile, no root isolate is
> created, and the app hangs on a blank screen with
> `Could not prepare isolate` in the engine log.

## Usage

```dart
final controller = JeelizFilterController(filter: TigerFilter())..load();

// Per tracked camera frame. Filters that sample the video (tiger does,
// glasses does not) want the camera buffer first:
if (controller.needsVideo) {
  controller.feedLumaPlane(nv21YPlane, width, height,
      rowStride: rowStride, rotationDegrees: sensorOrientation);
}
// Landmarks normalised 0..1 in the upright, un-mirrored source image, or
// null when no face was found:
controller.feedLandmarks(landmarks, sourceSize);

// In build():
Stack(children: [
  CameraPreview(cam),
  JeelizFilterOverlay(controller: controller, mirror: true),
]);
```

The library takes no camera or ML dependency. It accepts landmarks (and
optionally raw camera bytes) and returns a `ui.Image`, so it drops into
whatever capture pipeline the host app already has.

## A note on asset keys

Flutter namespaces assets by whoever owns them at build time, and this package
gets loaded both ways:

- as a **dependency** (from `beauty-filters/app`) — keys are
  `packages/jeeliz_dart/assets/…`
- as the **running app** (`flutter run` here) — the root package's assets get
  bare keys, `assets/…`

Hard-coding either breaks the other. `src/core/assets.dart` probes both roots
on the first load and remembers which one worked, so the same code runs in the
demo, in a host app and under `flutter test`.

## What maps to what

| Original | Here |
| --- | --- |
| `helpers/JeelizThreeHelper.js` | `src/tracking/face_filter_helper.dart` |
| `demos/.../JeelizThreeGlassesCreator.js` | `src/filters/glasses_vto.dart` |
| `demos/.../main.js` (`init_threeScene`) | `buildGlassesScene()` |
| `THREE.Object3D` / `PerspectiveCamera` | `src/core/scene.dart` |
| `THREE.BufferGeometryLoader` | `src/core/geometry.dart` |
| `THREE.WebGLRenderer` | `src/render/renderer.dart` |
| `ShaderLib.standard` + branch fading | `FramesMaterial` |
| `MeshBasicMaterial` + envMap | `LensesMaterial` |
| `create_threejsOccluder` | `OccluderMaterial` |
| `demos/CSS3D/comedy-glasses/main.js` | `src/css3d/css3d_transform.dart` |
| `demos/faceReplacement/image/main.js` | `src/faceswap/art_painting.dart`, `src/faceswap/face_swap.dart` |
| `demos/threejs/celFace/main.js` | `src/filters/cel_face.dart` |
| `demos/threejs/celFace/shaders/celFragmentShader.gl` | `src/filters/cel_material.dart` |
| `demos/threejs/butterflies/main.js` | `src/filters/butterflies.dart` |
| `demos/threejs/matrix/main.js` | `src/filters/matrix.dart` |
| `demos/threejs/matrix/matrixRain.mp4` | `src/filters/matrix_rain.dart` (synthesised — see below) |
| `demos/threejs/luffys_hat_part1/main.js` | `src/filters/luffys_hat.dart` (`LuffysHatPart.part1`) |
| `demos/threejs/luffys_hat_part2/main.js` | `src/filters/luffys_hat.dart` (`LuffysHatPart.part2`) |
| `demos/threejs/gltf_fullScreen/main.js` | `src/filters/gltf_helmet.dart` |
| `demos/threejs/fireworks/main.js` | `src/filters/fireworks.dart` |
| `demos/threejs/halloween_spider/main.js` | `src/filters/halloween_spider.dart` |
| `libs/three/v112/GLTFLoader.js` | `src/core/gltf.dart` |
| three's `CubeTexture` + `envmap_physical_pars_fragment` | `src/core/texture.dart`, `src/core/standard_materials.dart` |
| CSS `matrix3d()` + `perspective()` | `Css3dPose.matrix` -> Flutter `Transform` |
| the tracked `div` | `JeelizCss3dOverlay` |
| `demos/threejs/multiLiberty/main.js` | `src/filters/multi_liberty.dart` |
| `JeelizThreeHelper.sortFaces` | `sortGeometryFaces` |
| `THREE.CustomBlending` (SrcColor/One/Add) | `BlendMode.srcColorAdd` |
| `demos/threejs/cloud/main.js` | `src/filters/cloud.dart` |
| `THREE.PointLight` | `PointLight` + `pointLightAttenuation` |
| `demos/threejs/dog_face/main.js` | `src/filters/dog_face.dart` |
| `FlexMaterial/ThreeFlexMaterial.js` | `src/core/flex_material.dart` |
| `THREE.JSONLoader` (`Geometry` format) | `src/core/legacy_geometry.dart` |
| `AnimationMixer` + morph clip | `_TongueAnimation` in `dog_face.dart` |
| `bumpMap` / `perturbNormalArb` | `PhongMaterial._perturbNormalArb` |
| `glfx.js` `vignette()` | `DogFaceFilter._buildVignette` |
| `demos/threejs/rupy_helmet/main.js` | `src/filters/rupy_helmet.dart` |
| its face-fill `ShaderMaterial` | `HelmetFaceMaterial` |
| `MeshStandardMaterial` (no envMap) | `StandardMaterial` |
| `demos/threejs/casa_de_papel/main.js` | `src/filters/casa_de_papel.dart` |
| `MeshPhongMaterial` + `perturbNormal2Arb` | `PhongMaterial` + `SoftwareRenderer._computeTangentFrame` |
| `helpers/addDragEventListener.js` | `CasaDePapelFilter.maskOffset` |
| `demos/threejs/tiger/main.js` | `src/filters/tiger.dart` |
| its `build_customMaskMaterial()` | `src/filters/tiger_material.dart` |
| `MeshLambertMaterial` / `MeshBasicMaterial` / `SpriteMaterial` | `src/core/standard_materials.dart` |
| `TWEEN.js` | ~30 lines of linear interpolation in `tiger.dart` |
| `JEELIZFACEFILTER` (the neural net) | **not ported** — see below |

`update_poses`, `detect`, `create_camera` and `update_camera` are transcribed
line for line. The demo's placement constants (`dy = 0.07`, glasses scale
`0.006`, occluder scale `0.0084`, `pivotOffsetYZ = [0.2, 0.6]`) are used
unchanged, which is the whole point of keeping three's coordinate and storage
conventions.

## The CSS3D path

`comedy-glasses` is not a `JeelizFilter` and never touches the rasteriser. Its
demo has no three.js scene: the filter is one `div` with a background image,
placed by a CSS `matrix3d()`. The Flutter analogue is exact — a `Matrix4` on a
`Transform` — so that is what the port produces:

```dart
final css = JeelizCss3dController();
css.feedLandmarks(landmarks, sourceSize, overlaySize);

// In build():
JeelizCss3dOverlay(controller: css, child: const ComedyGlassesImage());
```

Worth knowing for its own sake: for a flat sprite — glasses, a moustache, a hat
— this beats a 3D scene on both cost and sharpness. There is no framebuffer and
no per-pixel work at all; the GPU composites the image at native resolution.
Nothing else in this table is under a millisecond.

The demo carries its **own** pose maths, not `JeelizThreeHelper.update_poses`,
and the differences are all deliberate:

- `D = 1/(2·W·tanFOV)` is the distance to the cube's *front face*, with the
  centre then taken as `-D - 0.5`. The three.js helper folds that half-edge in
  earlier.
- The Euler is `(-rx - offset, -ry, rz)` in **XYZ** order rather than
  `(rx, ry, rz)` in ZYX. The sign flips are not noise: `-rx` converts Y-up view
  space into CSS's Y-**down** screen space, `-ry` mirrors the yaw to match the
  flipped preview, and `rz` flips twice so comes out unchanged. Flutter's widget
  space is *also* Y-down, so the conversion carries over untouched.
- `perspectivePx` divides by `tan(fov · PI/180)` — the **whole** field of view,
  not half of it.

And the part that looks wrong until you do the arithmetic: the element is sized
to the whole canvas and scaled 1.3x, which sounds enormous. But it is placed far
enough back that the perspective divide brings it to about **1.26x the head
width** — which is exactly what comedy glasses should be. There is a test for
that number.

The `mouthOpened` / `mouthClosed` CSS classes the demo toggles are *empty rules*
in its own stylesheet, so nothing moves; they are a styling hook. The signal is
still there as `Css3dPose.isMouthOpen`.

## The face-replacement path

`faceReplacement/image` is the third kind of thing here: no scene, no widget
transform, just two images drawn on top of each other. It also inverts the
usual arrangement — the camera is sampled but never shown, and the painting is
what you look at.

```dart
final art = ArtPaintingController();
await art.loadPainting('artPainting/Joconde.jpg', kJocondeFace);
// Per frame: art.feedLumaPlane(...) then art.feedLandmarks(...)
// In build():
ArtPaintingView(controller: art);
```

Once per painting: cut a head-shaped hole in it, and reduce the face that used
to be there to a 4x4 colour signature. Per frame: crop the user's face with the
same box formula, reduce *that* to its own 4x4 signature, and shift the crop's
HSV from one signature towards the other. Draw the crop, then the holed
painting over it.

The colour step is what makes it work. Without it you get a photograph pasted
into an oil painting; with it, a face that shares the painting's palette. The
transform is per-pixel and local: hue shifts by the difference between the two
signatures at that point, saturation and value scale by the ratio, both clamped
to `[0.3, 3]` so a near-black cell cannot send the ratio to infinity. Value
carries a deliberate extra `0.8` — a fully matched value looks flat.

Four details in the original that are easy to miss, and all four are ported:

- The hole is **head-shaped**, not elliptical: a circular arc for the forehead
  above `y = 0.7`, another for the jaw below `y = 0.5`, straight sides between
  them. Above the forehead line the arc is also blended with a plain vertical
  fade towards the centre, so the top of the skull gets no hard rim.
- Alpha is then **modulated by luminance** — `mix(pow(a,0.5), pow(a,1.5),
  smoothstep(0.1, 0.5, gray))`. Dark paint (hair, shadow) keeps more of the
  painting; lit paint gives way to your face sooner. It is why the Mona Lisa's
  hair still frames your face.
- The signature crop clamps every sample to **radius 0.8** of the frame centre,
  so a face near the edge of frame cannot drag the border pixels into the
  palette. The displayed crop is *not* clamped — only the signature is.
- The mask is drawn under `blendFunc(SRC_ALPHA, ZERO)`, which multiplies every
  channel by the source alpha — leaving `colour*alpha` in RGB but `alpha²` in
  A. Almost certainly not deliberate; `blendFunc` was reached for to overwrite,
  not to blend. It is kept because it is what the demo looks like: the squared
  falloff is a wider, softer seam. It also means the outermost few percent of
  the fade quantise to zero in 8 bits.

The demo's `copyInvX` step is the one thing **not** carried over, and
deliberately. It flips the painting's signature horizontally to cancel the
`uv = vec2(1.-vUV.x, vUV.y)` in its final shader, which samples both signatures
mirrored. Here the signature is sampled at the output pixel's own u, so there is
nothing to cancel — flipping as well would swap the palette across the face.
`hueSignature(..., flipX: true)` still exists so a test can show the difference.

### Finding the painting's face

The demo runs its CNN over the still image until it accumulates 25 positive
detections, then averages them — its detector is a video tracker with no
still-image entry point. MediaPipe has one, so `PaintingFaceLocator`
(`lib/demo/`, not the library) decodes the image, runs one pass, and hands the
landmarks to `ArtPaintingController.locateFace`, which returns the same
`DetectState` a camera frame would produce. The Mona Lisa short-circuits to
`kJocondeFace`, the answer the demo hard-codes to skip its own search.


## The render-to-texture chain

`celFace` is the first port that needs more than one pass. The demo runs four
scenes, and each does something the previous one could not:

```
scene0 -> target0   the low-poly head, toonified. Opaque inside the silhouette,
                    cleared outside — so target0's *alpha* is the head's shape.
scene1 -> target1   7-tap Gaussian on alpha only, horizontally.
scene2 -> target2   the same, vertically.
scene  -> screen    the video, with target2 mixed over it.
```

`JeelizFilter.postProcess(Framebuffer)` exists for exactly this: a chance to
sweep the finished framebuffer before it becomes an image. Nothing else here
uses it.

The last pass needs no port at all. `mix(videoColor, faceColorTweaked,
faceColor.a)` is source-over with straight alpha, which is what Flutter already
does when it composites this overlay onto the camera preview underneath — so
the demo's full-screen video quad disappears and the filter just writes tinted
colour and blurred alpha.

Two lines carry the whole effect.

**`if (colCenter.a == 0.0) { alphaBlured = colCenter.a; }`** — a pixel that was
outside the mask stays outside. Without it the blur would spread the mask
outward into a halo; with it the feather can only eat *inward*, so the toon face
shrinks slightly and its border dissolves into the real camera image rather than
ending on a polygon edge. That is why 974 triangles never look like 974
triangles. `pow(alphaBlured, 2.)` then runs on *each* pass, so the two together
are a fourth power and the feather bites hard: half coverage in both axes lands
at 6%, not 25%.

**`dot(LUMA, faceColor.rgb) * FACECOLOR`** — all the hue and saturation
quantisation the cel shader just did is thrown away and replaced with one warm
off-white (`1.2 * vec3(242, 236, 230) / 255`, deliberately over 1 on red so
highlights clip to paper white). What survives is brightness — three posterised
bands — plus the black edges. Cartoon ink and paper, not a colour-quantised
photograph.

### What the cel shader actually does

It is a screen-space effect wearing a mesh. Nothing about the geometry reaches
the colour except the silhouette: each fragment samples the camera at its own
projected screen position, posterises it in HSV, and paints it black if a 3x3
intensity operator says it sits on an edge. `faceLowPoly.json` ships positions
and indices only; the demo calls `computeVertexNormals()` and the shader never
reads a normal.

The quantisers are worth reading closely, because three of their quirks are
load-bearing and a "fix" would change how the filter looks:

- **The hue partition is lopsided.** 0-140 collapses to 140, a sliver to 160,
  160-240 to 240, and 240-360 to 360 — and through `HSVtoRGB` those four bands
  are only four hues: green, green-cyan, blue, magenta. The first band swallows
  the entire warm half of the wheel, so **skin comes out green**. That sounds
  ruinous and is not, because the composite keeps only luma and green carries
  the largest luma weight — the net effect is a toon face slightly brighter than
  a neutral desaturation. The magenta band catches lips and strong pinks.
- **Hue 360 is magenta, not red.** `h/60 == 6` gives `i == 6`, a sector the
  shader's `if (i==0..4)` chain does not name, so it falls through to the i==5
  case.
- **Nothing stays achromatic and nothing stays black.** `nearestLevel1` rounds
  everything below 0.15 *up*, despite its own comment listing 0.0 as a level, so
  grey picks up a cast. And black takes the `RGBtoHSV` early return, `(-1, 0,
  0)`, which the three quantisers round to `(140, 0.15, 0.3)` — a dark greenish
  grey at 30% value. The only true black in the output is the edge ink, which is
  written after the HSV path rather than through it.

Two deliberate divergences, both about resolution rather than maths. The edge
operator's step is `1.0 / videoSize` where `videoSize` is the *canvas* size, and
the demo's canvas is sized to its video, so it reaches one video pixel; here the
video texture has its own smaller size and its own texel is used, keeping the
operator tied to the image it reads instead of drifting with the render slider.
And the blur's tap spacing is scaled against a 600px reference rather than taken
in target pixels, so the feather stays the same fraction of the face at every
render resolution instead of quadrupling across the slider's range.

## Animation without an AnimationMixer

`butterflies` is the first port that uses three's animation system, and it
turns out not to need it.

`THREE.JSONLoader` sees 106 morph targets named `animation_000000` upwards and
calls `AnimationClip.CreateClipsFromMorphTargetSequences(morphTargets, 10)`.
That builds one `NumberKeyframeTrack` per target with a triangular ramp — 0 at
frame `g-1`, 1 at `g`, 0 at `g+1` — so at any moment exactly two adjacent
targets are active and their influences sum to 1. That is linear interpolation
between consecutive frames, and evaluating it directly is exactly equivalent to
running a mixer over 106 tracks, for a fraction of the machinery:

```dart
var frame = (wingTime + wingPhase) * 10.0;   // the loader's hard-coded fps
frame %= 106;
influences[frame.floor()]       = 1 - frac;
influences[(frame.floor() + 1) % 106] = frac;
```

Clip length is 106 frames at 10 fps, so one cycle is **10.6 seconds** of clip
time. The demo advances it with `m.update(0.13)` — a **fixed** step, once per
`callbackTrack`, not the real elapsed time — so a cycle takes ~82 rendered
frames however fast those frames arrive. That is reproduced as written, because
the author picked 0.13 by eye against their own frame rate and it sets how the
wings beat relative to the orbit. `wingStepSeconds = null` switches to real
time.

The flight path is treated the other way round. `animateFly` runs on a
`setInterval(..., 16)`, which is a wall-clock timer, so it is driven from real
elapsed time — the intent, and on a browser that is keeping up, also the
behaviour.

### The demo's quirks, all reproduced

- **`for (let i = 2; i <= NUMBERBUTTERFLIES; i++)`** with
  `NUMBERBUTTERFLIES = 10` gives **nine** butterflies. `i` is also the
  animation's phase parameter — it scales the orbit offset and the vertical
  rate — so starting at 2 changes what the swarm looks like, not just how many
  of it there is.
- **The second material is never drawn.** The mesh is built as
  `[materialWings, materialBody]`, but no face in `butterfly.json` sets bit 1
  of its bitfield, so every triangle is material 0. (`materialBody` also has
  `opacity: 0` without `transparent: true`, so had it ever been used it would
  have been an opaque black blob.)
- **`animateFly(mesh, theta, index)` never reads `theta`**, and `sign` is
  computed for every butterfly and thrown away.
- **The random start position is not a position.** The first tick of
  `animateFly` overwrites all three components, so `xRand/yRand/zRand` survive
  only as the *radii* of the orbit — every butterfly begins at `(x, 1, 0)`
  whatever its random y and z were.
- **There is no ambient or directional light in the scene at all.** The only
  illumination is the nine cyan point lights, each tweening down to zero. A
  butterfly at the bottom of its cycle is a black silhouette, not an invisible
  one — its alpha map still cuts the wing shape out. The glow is the entire
  lighting model. Their `distance: 1, decay: 0.1` is three r97's non-physical
  falloff, `pow(1 - d/cutoff, decay)`, which stays above 90% at half the cutoff
  and then collapses.

The light tween is a chain — `to({intensity: 0.6}, 2000)` then
`to({intensity: 0}, 2000)`, restarting the first on completion — and the light
is *constructed* at intensity 1. So the opening ramp runs 1 → 0.6 once and
every ramp after it runs 0 ↔ 0.6. Linear, which is TWEEN.js's default easing.

### grass.png is not a screen-space quad

Every other foreground here (casa_de_papel's `calque.png`) is a full-screen
quad, and `JeelizFilterOverlay` stretched it to fill. The grass is a 1600x227
strip placed by CSS — `width: 100vmin; bottom: -5px; left: 50%;
translateX(-50%)` — so filling would smear it over the whole screen.
`JeelizFilter.foregroundLayout` now picks between the two; `fill` stays the
default, so nothing else changed.

## The filter that replaces the camera

Every other port draws *over* a live `CameraPreview`. `matrix` does not, and
the reason is one line of its `init_scene`:

```js
threeInstances.videoMesh.material.uniforms.samplerVideo.value = videoTexture;
```

That reaches into JeelizThreeHelper's full-screen background quad — the one at
`renderOrder = -1000` with `depthWrite: false, depthTest: false` — and swaps
the camera texture for `matrixRain.mp4`. So the camera is never *shown*. It is
only sampled, by the mask, as a green-keyed brightness signal.

Every other port simply drops that quad, because the preview underneath already
is the camera. This one has to draw it, so `JeelizFilter.preRender(Framebuffer)`
exists: a chance to paint under the scene, straight after the clear and before
any geometry. It writes colour only — the clear has already set depth to 1.0 and
the scene pass depends on that. `matrix` is the only user, and its output is
fully opaque, so the preview beneath the overlay is simply covered. (The camera
keeps running: the mask needs it.)

### The mask has no edge

The fragment shader does three things at once — a green key of the camera, the
rain again at refracted UVs, and two fades — and then composites them in one
line:

```glsl
vec3 finalColor = colorCamera * isInsideFace + colorLineCode;
```

`colorLineCode` is added at **full strength**, un-attenuated. `isInsideFace` is
`(1 - pow(length(vNormalView.xy), 3)) * (1 - isNeck)`, so it reaches 0 at the
silhouette and below the jaw — and `uvRefracted` is mixed back to plain `uv`
over the same term. Where the mask fades out, its pixels become *exactly* the
background behind them. There is nothing to see the join of. A test pins this:
shading a fully tangent normal must equal an unrefracted background sample to
within floating-point noise.

The green key is deliberately over-driven — `luma * vec3(0, 1.5, 0)`, so a lit
face clips to solid green instead of shading — with `smoothstep(0.3, 0.6, luma)`
adding a white specular kick on top. The refraction is
`refract(vec3(0, 0, -1), vNormalView, 0.3)` scaled by 0.1, which is zero
head-on (a view-aligned normal has no xy), largest across the cheeks, and mixed
away again at the rim.

One thing in the original is wrong and inert: the vertex shader writes
`vNormalView = vec3(viewMatrix * vec4(normalize(transformedNormal), 0.))`, but
`<defaultnormal_vertex>` has already put `transformedNormal` in view space, so
the view matrix is applied twice. It costs nothing because JeelizThreeHelper
never moves or rotates its camera, leaving `viewMatrix` an identity.
Transcribed as a single view-space normal.

### The rain is synthesised, not decoded

This is the one place in the port where the imagery is not the demo's own.

`matrixRain.mp4` is 6.5 MB of H.264, handed to three as a `VideoTexture`. That
cannot be reproduced here, and not for want of a video plugin: the shader
samples the rain at *refracted* UVs, per fragment, and the renderer is a
software rasteriser — it needs the pixels on the CPU every frame.
`video_player` hands back a platform texture only the GPU can read, and no
Flutter API decodes a video frame into memory. Building a sprite sheet offline
would need an H.264 decoder to make it.

So `MatrixRain` generates it: columns of glyphs with randomised speed and tail
length, a pale leading character, a quadratic fade behind it, and a few glyph
mutations per second so the columns read as writing rather than as bars. It
costs no asset at all, and the shader only ever wanted a mostly-black field with
bright green columns.

The glyphs are procedural 5x7 dot patterns rather than rasterised text. Real
glyphs would mean a `ParagraphBuilder` and `toByteData` round trip at load, a
dependency on which characters the platform font happens to have, and a test
suite that behaves differently under the test font. At this size — refracted,
green, behind a face — glyph identity is invisible; density and rhythm are not.
Each pattern is random with two constraints that make it read as writing: no
empty rows, and a lit spine down the middle.

Everything about the *effect* is still a straight transcription. Only the source
imagery differs.

## One filter, two demos: luffys_hat

`luffys_hat_part1` and `luffys_hat_part2` are the same straw hat before and
after the author finished the job. Part 2 re-textures it, re-seats it, adds the
low-poly face fill that hides your real hairline under the brim, moves the
tracking pivot, makes the group draggable and frames the result. Everything
that differs is data, so they are one `LuffysHatFilter` with a
[`LuffysHatPart`] switch rather than two files.

Two things came out of it that are worth naming.

**The face fill is rupy_helmet's shader with two constants changed** — the
silhouette fade runs `smoothstep(0., 0.85, ...)` instead of `0.55`, and the
darkening `smoothstep(-0.15, 0.15, ...)` instead of `0.05`. Both widen the
band, which suits a mask that has to disappear under a straw brim rather than
inside a helmet shell. `HelmetFaceMaterial` now takes them as parameters
defaulting to rupy's, instead of the port carrying a near-duplicate material.
`faceLowPolyEyesEarsFill2.json` is byte-identical between the two demos too, so
part 2 loads rupy's copy rather than shipping it twice.

**The tracking pivot is not a scene-graph property.** Part 2 calls
`JeelizThreeHelper.set_pivotOffsetYZ([0.2, 0.6 - 0.1])` *before* init — it moves
the point the head appears to rotate about, so the hat swings with the head
instead of sliding across it. No mesh transform can express that, so
`JeelizFilter.preferredPivotOffsetYZ` declares the need and whoever builds the
controller passes it through `JeelizHelperSettings`. A test renders the same
probe under both pivots with the head pitched, and checks the results actually
differ — it would be an easy knob to wire up and silently ignore.

### Part 1's three dead lines

Each of them looks load-bearing, and all three are reproduced as written:

- **`hatMesh.rotation.set(0, -40, 0)`.** three's Euler is in **radians**, so
  this is −40 rad ≡ 3.98 rad, about 228°. Almost certainly a typo for −40
  degrees. Kept, because it is where the bow actually sits on screen — part 2
  quietly drops it to `(-0.1, 0, 0)`.
- **`hatMesh.side = THREE.DoubleSide`.** `side` is a *material* property.
  Assigned to the mesh it is an inert field, so the hat stays front-faced. Part
  2 does the same thing again.
- **`new THREE.AmbientLight(0xFFFFFF, 0.8)`.** The hat is a
  `MeshBasicMaterial`, which is unlit. Part 2 adds the same light, and both of
  its materials are unlit or custom, so it does nothing there either. Neither
  light is ported; a test asserts the scene has none.

`BasicColorMaterial` gained a `map` for this — `MeshBasicMaterial` has always
had one, and the cloud and casa_de_papel just never used it.

## glTF, cube maps, and a helmet lit by nothing

`gltf_fullScreen` is fifty lines of demo on top of three capabilities the port
did not have. All three live in `core/`, so the next glTF filter is cheap:

- **`src/core/gltf.dart`** — a glTF 2.0 reader. Deliberately not general: it
  covers external and base64 buffers, byte strides, the five component types,
  SCALAR/VEC2/VEC3/VEC4, node TRS and node matrices, and metallic-roughness
  materials, and it **throws** on anything else (sparse accessors, `.glb`,
  skins, non-triangle primitives). A geometry loader that guesses produces a
  model that looks *almost* right, which is far harder to notice than a stack
  trace.
- **`CubeTexture`** — six faces with a box-filtered mip pyramid, sampled by
  direction. The pyramid is the point: `MeshStandardMaterial` reads the
  environment at a roughness-dependent level, so a polished surface reflects a
  sharp cube and a rough one a blurred one.
- **`MeshStandardMaterial`'s remaining half** — normal, packed
  metalness/roughness, AO, emissive, sRGB decoding, and cube-map IBL.

### The helmet is lit by nothing

This is the fact that decides how the whole filter looks, and it took reading
three's shader chunks to be sure of:

- main.js adds **no lights**. No ambient, no directional, nothing.
- `<lights_fragment_maps>` gates environment *diffuse* on
  `ENVMAP_TYPE_CUBE_UV`, which means a PMREM-processed map.
  `CubeTextureLoader` produces a plain `ENVMAP_TYPE_CUBE`, so `iblIrradiance`
  stays **zero**.
- Which leaves environment **specular** as the entire lighting model, plus the
  emissive map for the glowing vents.

So the helmet is lit only by what it reflects. That reads correctly because the
model is almost entirely metal, and for a metal the specular colour *is* the
albedo — run the same setup on a dielectric and it comes out nearly black. A
test pins exactly that comparison, because "add a diffuse IBL term to fix the
darkness" is the obvious wrong fix and it would wash the helmet out.

The specular path is three's, transcribed:
`reflect(-viewDir, normal)` bent back toward the normal by `roughness²`,
`getSpecularMIPLevel(roughness, maxMip) = maxMip + log2(PI·r²/(1+r))` picking
the blur level, `flipEnvMap = -1` mirroring x on the way into the cube (cube
maps are specified left-handed), and Karis's analytic
`BRDF_Specular_GGX_Environment` fit so no lookup table is needed. AO occludes
the specular through `computeSpecularOcclusion` — with no indirect diffuse
present, that is the only half of `<aomap_fragment>` that does anything.

### Two details that would quietly break it

**glTF's material defaults are not three's.** A `pbrMetallicRoughness` that
names no factors is `metallicFactor = 1, roughnessFactor = 1` — fully metallic
and fully rough. This model names neither, so getting the defaults wrong turns
a metal helmet into a plastic one.

**sRGB textures come out darker than the JPEG.** GLTFLoader tags `map` and
`emissiveMap` (and nothing else) as `sRGBEncoding`, so the shader decodes them
to linear — and since neither the demo nor the helper sets
`renderer.outputEncoding`, that linear value is written straight to the
framebuffer. The result is visibly darker than the source image. That is what
the demo shows, so `StandardMaterial` carries `mapIsSrgb` /
`emissiveMapIsSrgb` rather than quietly "correcting" it.

`Object3D.localMatrixOverride` was added for this: glTF nodes may carry an
arbitrary 4x4, and this one carries a quaternion that stands the helmet
upright. Decomposing it back into a TRS with an Euler is lossy for no gain, so
the matrix is kept as-is.

`followZRot: true` in the init options needs no port. It asks the detector to
estimate head roll, and the landmark adapter here always solves `rz`.

## fireworks, or: reproducing the bugs on purpose

`fireworks` needed no new machinery at all — additive sprites and tweens have
been here since the tiger. What it needed was care, because almost every number
in it is off by something, and every one of those is visible.

- **`for (let i = 0; i <= SETTINGS.numberRockets; i++)`** with
  `numberRockets = 9` builds **ten** rockets. butterflies has the same `<=`
  mistake in the other direction — its loop starts at 2 and produces *fewer*
  than the constant says. The same pattern gives **101** particles per burst,
  not 100, so the demo runs 1,010 sparks.
- **`theta = Math.log10(Math.random() * 2 * Math.PI)`.** The logarithm of an
  angle. Almost certainly meant to be the angle. `log10` of a uniform draw over
  `[0, 2π)` sits mostly in `[0, 0.8]` radians, so `sin(theta)` is nearly always
  positive and the burst is a **fan going up**, not a ring. A test asserts that
  asymmetry directly — more than 45 of 60 sparks end above the origin, where a
  real angle would give about half.
- **`particle.rotation._z = particle.rotation.z * Math.random()`** is inert
  three ways over: it writes three's *private* Euler field so no change
  callback fires and the quaternion never updates; it multiplies by a `z` that
  is zero; and a Sprite takes its roll from `material.rotation`, not the
  object's.
- **`particle.scale.multiplyScalar(3)`** is overwritten by
  `scale.x = scale.y = Math.random() * 0.1` before the particle is ever drawn.
  `scale.z` keeps the 3, and a Sprite ignores it.
- **Particles are shown and never hidden.** Once a burst finishes they sit at
  their end position at scale 0.0001 — sub-pixel, but still submitted every
  frame. That is where the 1,013-mesh figure in the performance table comes
  from.

### The sprite is code, not an image

`generate_sprite(color)` paints a 32x32 canvas with a radial gradient, and the
stop list is the interesting part:

```js
gradient.addColorStop(0.5, 'rgba(255,255,255,1)');
gradient.addColorStop(0.2, 'rgba(0,255,255,1)');
gradient.addColorStop(0.5, color ? color : 'blue');
gradient.addColorStop(1, 'rgba(0,0,0,0.1)');
```

The stops are **out of order** — 0.5, then 0.2, then 0.5 — and there are **two
at 0.5**. Canvas sorts by offset while keeping insertion order for ties, and
resolves a duplicate offset as a discontinuity: the earlier-added colour applies
up to it, the later-added from it. So the sprite reads flat cyan out to 20% of
the radius, ramps cyan to white by 50%, **jumps** to the burst colour, and fades
to `rgba(0,0,0,0.1)` at the rim. Sorting the stops "properly" would give a
completely different sprite.

Two smaller details carried over: canvas interpolates gradients in
**premultiplied** space, which is why that last segment stays saturated as it
fades instead of going muddy; and the gradient's radius is half the canvas, so
the corners fall past its end and take the final stop flat.

CSS `green` is **#008000**, not #00FF00 — two of the ten bursts are that muted
dark green.

### One deliberate divergence

The demo puts `frame_fireworks.png` in the scene at `renderOrder = 999` while
the sprites sit at `100000`, so in the original the sparks draw *over* the
border. This port uses `JeelizFilter.foreground`, which paints the frame above
everything and outside the mirror transform — the same treatment casa_de_papel,
rupy_helmet and luffys_hat_part2 already get. The visible difference is confined
to sparks crossing the outer border, and consistency with the other three framed
filters is worth more than that.

## halloween_spider: a filter that waits for you

Every other port runs the moment it loads. `halloween_spider` does nothing
until `detectState.expressions[0] >= 0.8` — mouth open — and then plays a
121-frame morph animation on two spiders exactly **once** before resetting and
arming again. An `isAnimating` flag stops a held-open mouth from restarting the
clip every frame.

The one-shot is achieved oddly in the original. `action.loop = false` sets
three's `loop` property to `0`, which is not `LoopOnce` (2200) — so
`AnimationAction._updateTime` takes the *repeat* branch and the clip loops. The
demo then subscribes to the mixer's `'loop'` event and calls `stop()` and
`reset()` there. It plays once by starting to loop and being caught. Ported as
what it does rather than how it does it.

Two more details carried over: `mixer.update(0.08)` is a **fixed** step per
rendered frame rather than real elapsed time (butterflies' 0.13 again), and
both the trigger and the mixer sit inside `if (ISDETECTED)`, so losing tracking
freezes the spiders mid-crawl and finding it again resumes them where they were.

### Four dead things, two of them whole assets

- **`models/face/diffuse_makeup.png`** is loaded into a `MeshBasicMaterial`
  that is then discarded — `faceMesh` is built with `materialVideo` instead. The
  makeup never reaches the screen, so this port does not ship the file.
- **The face shader computes `darkenCoeff` and `borderCoeff` and outputs
  neither.** `gl_FragColor = vec4(videoColor, 1)`. It is rupy_helmet's face
  shader with its two commented-out debug outputs left in and the real one
  deleted, so what remains is an *opaque redraw of the camera at the face's
  position*. It looks like nothing when your head is bare, and that is the
  point: it gives the spiders something to disappear behind.
- **An `AmbientLight` and a `SpotLight`** are added to the scene. Both spiders
  are `MeshBasicMaterial`, which is unlit, and the face is a custom shader.
  Neither light can affect anything, and a test asserts the ported scene has
  none.
- **Both spider JSONs carry 80 bones.** The meshes are plain `Mesh`es rather
  than `SkinnedMesh`es and the material never sets `skinning: true`, so the
  skeleton is inert — every bit of the movement is morph targets.

`diffuse_spider.jpg` is byte-identical between the two model directories, so it
is shipped and decoded once. The two spider *models* are not: same vertex and
face counts, genuinely different geometry, so they cannot share.

## The two things that are not straight transcriptions

### 1. Face tracking

Jeeliz's tracker is a convolutional net evaluated in GLSL against obfuscated
weights (`neuralNets/NN_DEFAULT.json`). There is no pure-Dart route to it, and
re-implementing it was not the goal.

Instead `LandmarkDetectStateAdapter` synthesises the same seven numbers the net
emits (`DetectState`: `detected, x, y, s, rx, ry, rz`) from face landmarks
supplied by the host app. Everything downstream of that boundary is the real
Jeeliz pipeline, and any other tracker — ARKit, ARCore, a future port of
Jeeliz's own net — can drive it by producing a `DetectState`.

The conversion is metric rather than fitted: solve a head pose from the
landmarks with POS (pose from orthography and scaling), then work out where a
unit cube has to sit for its projection to match. The two constants tying the
coordinate systems together were read off the demo's own assets, not tuned by
eye — see `JeelizCubeCalibration`.

Two subtleties are worth knowing about, because both are invisible until you
measure them:

- **POS fits a weak-perspective scale**, which under a real pinhole camera
  corresponds to the depth of the landmark *centroid*. Anchoring the cube
  anywhere else leaves the glasses correctly positioned but a few percent too
  large.
- **`update_poses` and the projection matrix disagree about the horizontal
  field of view.** Jeeliz computes `tan(aspect · fov / 2)` — scaling the angle
  by the aspect ratio — while the projection matrix effectively uses
  `aspect · tan(fov / 2)`. Those differ by ~7% at a phone's portrait aspect
  ratio. The demo's asset scales were tuned on top of that mismatch, so the
  port keeps it: the adapter inverts `update_poses` with Jeeliz's value and
  computes where the head must be with the real one.

### 2. Rendering

`src/render/renderer.dart` is a software rasteriser with a real depth buffer.

That is not a stylistic choice. The filter needs depth for its own sake: the
face occluder is a mesh that writes depth and no colour, and it is the only
reason the temples disappear behind the head rather than being drawn across the
cheek. Flutter's `Canvas.drawVertices` has no depth buffer and no fragment
stage; `FragmentProgram` has fragments but no vertex stage. Neither can express
a depth-only pass, so the depth buffer has to be ours.

The output is a transparent RGBA image composited over the camera preview,
which takes the place of the full-screen video quad three renders underneath
the scene.

Shading follows three.js **r112** specifically (what the demo's `index.html`
loads), including its ACES tone-mapping curve — later three versions swapped in
a matrixed version that grades differently. The demo never sets
`texture.encoding` on the env map, so r112 treats the JPEG as linear and renders
brighter than physically correct; that is reproduced by default and can be
switched off with `decodeEnvMapAsSrgb`.

Note that the demo adds **no lights at all**. The frames are lit purely by
Fresnel-weighted reflection of `envMap.jpg` — indirect diffuse is genuinely
zero — and the lenses are that same map multiplied by `0x2233aa`.

The two filters do not even agree on colour management, and that is faithful
rather than sloppy: glassesVTO's main.js opts into ACES tone mapping and sRGB
output, while the tiger's (on three **r97**) sets neither, so the tiger writes
its linear result straight out. Tone mapping therefore lives per-material —
which is exactly where three puts it, in `<tonemapping_fragment>` — rather than
in a post pass. Running the tiger through ACES would visibly wash it out.

## Performance

The two filters are bound by opposite ends of the pipeline, which is worth
knowing before you reach for the resolution knob.

**glassesVTO** is vertex-bound: 19,048 triangles, 12,100 of them the occluder,
against only a few thousand covered pixels. Resolution barely moves it.

**tiger** is fragment-bound: 2,132 triangles but ~60k shaded fragments at 480,
because the mask covers a third of the frame and each fragment does a texture
fetch, a Lambert term, two eye-falloff tests and often a video fetch. Cost
scales close to linearly with area.

| Render target | glassesVTO | tiger | casa_de_papel | rupy_helmet | dog_face | cloud | multiLiberty (1 face) | celFace | butterflies | matrix | luffy 1 / 2 | glTF | fireworks | spider |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 180x320 | 5.2 ms | 6.8 ms | 6.9 ms | 11.1 ms | 3.2 ms | 5.0 ms | 10.7 ms | 6.4 ms | 6.8 ms | 6.4 ms | — | 20.8 ms | 1.2 ms | 9.4 ms |
| 270x480 | 6.4 ms | 13.6 ms | 13.2 ms | 18.8 ms | 5.8 ms | 6.6 ms | 17.5 ms | 12.5 ms | 10.7 ms | 14.6 ms | 5.9 / 11.4 ms | 34.2 ms | 1.9 ms | 11.1 ms |
| 360x640 | 8.3 ms | 21.1 ms | 16.7 ms | 29.4 ms | 8.6 ms | 8.6 ms | — | 21.6 ms | 12.2 ms | 25.1 ms | — | 56.5 ms | 2.8 ms | 14.0 ms |

**halloween_spider is cheap to draw and expensive to hold.** Frame time is
unremarkable, but its two spiders carry 121 morph frames each over 11,568
de-indexed corners — **32 MB** of `Float32List`, the largest resident cost of
any filter here, and ~450 ms to decode the two 5.6 MB JSONs. The `morphStride`
knob thins the frames if that matters; it changes the animation, so it defaults
to keeping all of them. The real fix would be keeping morph frames *indexed*
(1,988 unique vertices rather than 11,568 corners, a 5.8x saving) instead of
de-indexing them alongside the per-face UVs — that touches the renderer's hot
loop and dog_face and butterflies too, so it is noted rather than done.

**fireworks is the cheapest port here despite submitting the most objects** —
1,013 meshes a frame, against glassesVTO's one. Sprites are two triangles each
and the sparks shrink to 0.0001 within two seconds of bursting, so the whole
thing covers a few thousand fragments. It is a useful counterexample to reading
the mesh count as a cost: what matters is covered area.

**gltf_fullScreen is the most expensive port by some way**, and it is not the
15,452 triangles — it is what each of ~29k fragments does. Five texture fetches
(albedo, packed metal-roughness, normal, AO, emissive), then a cube-map sample
blended across two mip levels, then a tangent-space normal transform and the
GGX environment BRDF. One saving is exact and worth having: glTF packs
roughness and metalness into a single texture and GLTFLoader hands the same
object to both material slots, so the port detects that and fetches it once
instead of twice.

**matrix scales worst of everything here**, because it is the only filter that
touches every pixel: `preRender` fills the whole target with rain before the
scene runs, so its cost is the target's *area* with no geometry to bound it.
704 triangles are noise next to that. The render slider is the only knob that
matters for it.

**butterflies is vertex-bound like glassesVTO**, and for an unusual reason:
6,228 triangles but only ~4k covered fragments, and every one of its 2,076
vertices walks a 106-entry morph list nine times a frame. Only two entries are
ever non-zero, so almost all of that is a comparison — but there are 2 million
of them per frame. Resolution barely moves the number.

**celFace is fragment-bound too, and unusually so for its triangle count**: 974
triangles, but every one of ~24k fragments at 480 does *nine* bilinear RGB
fetches — one for the colour and eight for the edge operator — plus an HSV round
trip. Then the two blur passes sweep the whole target. Halving the render
dimension is the effective knob; lowering `videoLumaDimension` is not, because
that changes how the filter looks.

**multiLiberty is the most expensive port by a wide margin, and scales linearly
with face count:**

| Faces | 270x480 |
| --- | --- |
| 1 | 17.5 ms |
| 2 | 35.0 ms |
| 4 | 72.8 ms |

Both halves of that are inherent rather than fixable. The statue is 15,932
triangles *per face*, and — because the model's own face sits at its origin,
with the crown 6 head-heights above and the pedestal 16 below — it covers about
40% of the frame at any sensible head size. There is no clever culling to be had:
those pixels are genuinely statue.

So `maxFaces` is the lever, and it is close to perfectly linear. The demo's own
value is 4; 2 is a more realistic setting on a mid-range phone, and 1 makes it
comparable to rupy_helmet.

dog_face is the **cheapest** despite being the most featureful: 3,328 triangles
across three small meshes covering little of the frame. Feature count and cost
are unrelated here — covered area is what matters.

`cloud` makes the same point from the other direction. It draws **1,506
meshes** — three clouds and 1,503 raindrops — and still costs 6.6 ms, because
semi-transparent clouds and thin rain cover very little of the frame. Dropping
to 450 raindrops saves only 1.2 ms, so `dropsPerStream` keeps the demo's 501.
Most of what makes that viable is `Material.needsNormals`: the rain is unlit, so
1,503 inverse-transpose normal matrices per frame are skipped outright.

casa_de_papel sits in between: 12,238 triangles like the glasses, but a
normal-mapped Phong fragment is dear, so it scales with area too.

**rupy_helmet is the most expensive** — 14,924 triangles *and* the largest
covered area, with a textured Phong helmet, a translucent GGX visor over the
top of it (so most of the helmet is shaded twice), and a face fill sampling
colour video. Start it lower than the others on a mid-range phone. Colour video
extraction is 1.4 ms/frame against luma's 0.3 ms, which is not the bottleneck.

(Desktop JIT under `flutter test`; a phone running AOT will differ, and a
low-end phone will be slower.) Camera luma extraction is 0.3 ms and does not
show up.

`JeelizFilterController.maxRenderDimension` (default 480, the longest side) is
the knob. For glasses, raising it is cheaper than it looks and is the right fix
if the thin frame wires look aliased — the rasteriser does no anti-aliasing, so
frame definition is purely render resolution against physical screen size. For
tiger, raising it costs real time; lower it first if frames drop.

## Tests

`flutter test` — 111 tests, no device needed.

The load-bearing one is in `test/pipeline_test.dart`: it builds landmarks by
projecting the canonical head with a known pose, pushes them through the real
`landmarks → DetectState → update_poses → projection` chain, and checks the
head lands back where it started to under half a pixel, across six rotations.
Every constant in the tracking adapter is under test at once, which is the only
practical way to catch a sign error in the Euler extraction or the pivot
inversion short of pointing a phone at a face.

`test/render_assets_test.dart` renders the real glasses assets and checks what
the maths cannot reach: that the JSON parses, the env map decodes, the
materials produce colour, and the occluder hides the far temple on a turned
head without wiping out the lenses.

`test/tiger_test.dart` covers the tiger's own failure modes, all of which are
invisible until you are holding a phone: the four material groups tiling the
index buffer exactly, the jaw deformation rotating only the lower jaw (and
preserving length, as a rotation must), particles firing only above the
`mouthOpening > 0.5` gate and expiring afterwards, and — the important one —
that camera luma actually reaches the framebuffer, since without it the eye
region renders black rather than see-through.

`test/casa_de_papel_test.dart` pins the tangent frame, which is the piece with
the least visual tell — a mirrored or transposed basis still produces
plausible bumps, just lit from the wrong side, so it is checked against a
triangle whose answer is known by construction. It also pins the two
counter-intuitive behaviours: that an emissive map alone changes nothing, and
that bill motion is identical at 30 and 60 fps.

`test/rupy_helmet_test.dart` pins NV21's chroma layout — V before U, at half
resolution, so swapping them turns skin green — along with the face fill's two
independent falloffs and the fact that the group offset moves helmet, visor and
face fill together.

`test/dog_face_test.dart` covers four subsystems that all fail *quietly*: a
packed face stream walked with the wrong stride still yields plausible
geometry, morph influences that do not sum to 1 still render, a transposed bump
basis still looks bumpy, and a flex material with a wrong lagged matrix just
looks stiff. So the face stream is walked over a hand-built two-record fixture
with deliberately different strides, the morph influences are asserted to be a
partition of unity every frame, the bump normal is checked against a flat map
(must be a no-op) and a ramp (must not be), and the flex lag is checked to snap
on the first frame, trail on a jump, and converge when the target holds
still.

`test/cloud_test.dart` pins the point-light falloff against three's formula at
known distances, checks a zero-intensity light is dropped before it ever reaches
a shader (the lightning is dark for 3 of every 3.28 seconds), and counts the
flicker: two peaks per cycle, then a third only after the pause — which is what
distinguishes the chained double-flash from a single one.

`test/multi_liberty_test.dart` pins the things multi-face gets silently wrong
with one person in frame: that each slot has its own adapter and poses
independently, that every slot gets its own statue while still *sharing* one
15,932-triangle geometry, and that two faces really do draw more than one.
It also separates `srcColorAdd` from plain additive by measuring that a
half-grey source lands at 0.25 rather than 0.5.

`test/comedy_glasses_test.dart` has no framebuffer to look at — the entire
output is one matrix — so it checks that matrix against numbers worked out by
hand from the demo's constants: that the perspective uses the whole FOV rather
than half, that it lands as `-1/P` in the right cell, that both hysteresis
latches hold their state through the dead band, and that the element really does
come out at ~1.26x head width.

`test/art_painting_test.dart` checks the face-swap arithmetic where it is
checkable exactly: the box formula against the demo's four lines, the head
shape (narrower at the jaw than in the middle, opaque outside the box, a hole
at the centre), the luminance modulation in the direction it claims, the radial
clamp landing samples on the 0.8 circle, and the HSV pair round-tripping. The
colour transform is pinned at both ends — identical signatures leave hue and
saturation alone and scale value by exactly 0.8, and a black painting cannot
black out the face because the factor clamps at 0.3. One test asserts the
signature is *not* flipped, since that is the one place this port deliberately
diverges.

`test/cel_face_test.dart` pins the quirks above as behaviour rather than
accidents — skin landing in the green band, hue 360 coming back magenta, black
coming back as dark green-grey, saturation never reaching zero — because each
one looks like a bug and each one is what the demo does. The blur gets the
tests that matter for the look: that nothing outside the mask ever lights up,
that alpha falls monotonically towards the rim, that two squarings put the lip
under 25%, and that the feather stays the same fraction of the image at 120px
and at 240px.

`test/butterflies_test.dart` is mostly about *time*: when each butterfly
appears, where it is on its orbit, which two morph frames are blended, and
where its light sits in the tween chain. It also pins each of the quirks above
as intentional — nine and not ten, one material and not two, the light riding
its butterfly, no ambient light anywhere in the scene — since every one of them
reads like a mistake to fix.

`test/matrix_test.dart` splits along the same line. The rain is synthesised, so
its tests check what a viewer would notice — it falls, it fades behind the head,
it recycles instead of emptying the screen, overlapping columns never blow out
to white because they composite with `max` rather than `+`. The mask is a
transcription, so its tests pin the shader: the neck fade's exact -1.2..-0.85
span, the green key with no red or blue below the specular threshold, the
refraction being zero head-on and zero at the rim and non-zero between, and the
seam resolving to exactly the background.

`test/luffys_hat_test.dart` is mostly a diff between the two parts: what part 2
adds, what it re-seats, and what it moves out of the scene graph. The rest pins
part 1's dead lines as deliberate — the −40 radians, the front-facing material,
the absent ambient light — since each is exactly the sort of thing a port would
"fix" into looking wrong.

`test/gltf_helmet_test.dart` puts most of its weight on the loader, against
hand-built one-triangle files: accessor decoding, byte strides, normalised
integer attributes, the v flip, TRS composed as `T * R * S`, an explicit node
matrix going in column-major, and the refusals actually refusing. The material
tests pin the lighting claim directly — emissive alone with no env map, a metal
lit by nothing but a cube, a dielectric coming out darker than that metal, and
roughness picking a blurrier mip.

`test/fireworks_test.dart` is almost entirely a set of tripwires around the
list above: ten rockets and 101 sparks, the sprite being cyan at its centre and
discontinuous at half radius, CSS green being the dark one, the burst fanning
upward rather than ringing, and the sparks shrinking to 0.0001 while staying
visible forever. It also checks positions stay finite across several seeds —
`log10` of a near-zero draw goes to negative infinity, and a NaN vertex would
poison the rasteriser rather than merely look wrong.

`test/halloween_spider_test.dart` concentrates on the trigger, since that is
what is new: nothing moves below 0.8, holding the mouth open does not restart
the clip, it plays through once and clears its influences, it can be retriggered
after, losing the face freezes it rather than resetting it, and the fixed 0.08 s
step ignores real dt. The rest pin the four dead things above, including a
direct check that the face material ignores a silhouette normal and a below-jaw
position that rupy's version would have faded out.

## Porting the next filter

Implement `JeelizFilter` (`src/filters/filter.dart`) — `load()`, `attach()`,
and optionally `update()` / `setVideo()`. That is the whole surface; the
tracking, camera, scene graph, lights and renderer are shared, and
`JeelizFilterController` drives any of them.

What exists now covers most of `demos/threejs/`: indexed geometry with groups,
UVs and supplied normals; UV-mapped and equirectangular textures; Lambert,
Basic, Sprite and two custom shader materials; ambient + directional lights;
normal and additive blending; a depth-only pass; per-material vertex
deformation; and camera-video sampling.

Known gaps: no bone/skeletal animation — dog_tongue.json actually ships bones
and skin weights, but the demo drives it purely through morph targets so they
are parsed past and ignored; no shadow maps; no environment-mapped Phong or
Standard
(`reflectivity` is parsed but inert without one; `FramesMaterial` covers
image-based lighting separately), and `DetectState.expressions` currently
carries only mouth opening, so demos keyed to Jeeliz's other expression outputs
(`cubeExpr`'s eyebrow raise, for instance) would need those measured from
landmarks too.

Multi-face is supported end to end: `JeelizFilterController(maxFaces: n)` gives
`n` independently-smoothed tracking slots and `n` entries in
`helper.faceObjects`, and a filter clones its content into each the way
multiLiberty's `add_faceMesh` does. Feed it with `feedMultiFaceLandmarks`.
Slot assignment is the caller's job — pass faces in a stable order, or the
statues will swap heads between frames.

One simplification worth knowing if you port a filter that mixes opaque and
transparent materials on a *single* mesh: three splits its render lists per
geometry group, so such a mesh lands in both. The renderer here splits per
object, using the first material. No ported filter needs the difference yet.

Audio is also out of scope on purpose: casa_de_papel ships a soundtrack, and
playing it needs a plugin this library deliberately does not depend on.
`CasaDePapelFilter.startHeist()` is the hook to drive both the falling money
and your own audio from.
