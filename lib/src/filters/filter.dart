// What a ported filter has to provide.
//
// In the originals each demo is a whole page: its own index.html, its own
// main.js, its own copy of the boilerplate. The only parts that actually
// differ are the assets it loads, how it parents them to the tracked face
// object, and what it does per frame with the tracking state. That is exactly
// this interface, and everything else — camera, tracking, scene graph,
// renderer, compositing — is shared.

import 'dart:ui' as ui;

import '../core/video_texture.dart';
import '../render/renderer.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';

/// How a filter's [JeelizFilter.foreground] is placed over the render.
enum ForegroundLayout {
  /// Stretched across the whole overlay, which is what a screen-space quad
  /// does. casa_de_papel's `calque.png`.
  fill,

  /// Anchored to the bottom, horizontally centred, width `min(w, h)` and the
  /// image's own aspect ratio kept.
  ///
  /// This is butterflies' `grass.png`, whose stylesheet reads
  /// `width: 100vmin; bottom: -5px; left: 50%; transform: translateX(-50%)`.
  /// Stretching it to fill instead would smear a 1600x227 strip of grass over
  /// the whole screen.
  bottomVmin,
}

abstract class JeelizFilter {
  /// Decode assets and build meshes. Called once, before [attach].
  Future<void> load();

  /// Parent the loaded content to `helper.faceObject`, and add any lights to
  /// `helper.scene`. This is the `init_threeScene()` half of a demo's main.js.
  void attach(JeelizFaceFilterHelper helper);

  /// Undo [attach]. Only needed when swapping filters on a live helper.
  void detach(JeelizFaceFilterHelper helper) {}

  /// Per-frame hook — the `callbackTrack()` half. [dt] is seconds since the
  /// previous update, for animation that must not be tied to frame rate.
  void update(DetectState state, double dt) {}

  /// True when the filter samples the camera image in its shading, as the
  /// tiger's mask and the helmet's face fill both do. Controllers only pay for
  /// video extraction when some filter asks for it.
  bool get needsVideo => false;

  /// True when that sampling needs *colour* rather than just brightness.
  ///
  /// The tiger converts the video to grayscale in its first line, so luma —
  /// which NV21 hands over for free — is all it needs. rupy_helmet uses
  /// `videoColor.rgb` directly and does need the YUV->RGB conversion.
  bool get needsVideoColor => false;

  /// Hands over the latest camera luma. Only called when [needsVideo].
  void setVideo(VideoLumaTexture? video) {}

  /// A tracking setting this filter needs, or null to leave it alone.
  ///
  /// `luffys_hat_part2` calls `JeelizThreeHelper.set_pivotOffsetYZ([0.2, 0.5])`
  /// before init — it moves the point the head appears to *rotate about*, so
  /// this is not something the scene graph can express. Whoever builds the
  /// controller has to read this and pass it through
  /// [JeelizHelperSettings.pivotOffsetYZ].
  List<double>? get preferredPivotOffsetYZ => null;

  /// A chance to paint *under* the scene, straight after the clear.
  ///
  /// JeelizThreeHelper always adds a full-screen quad at `renderOrder = -1000`
  /// with `depthWrite: false, depthTest: false` — the camera background. Most
  /// demos leave it showing the camera, and this port drops it entirely
  /// because the overlay sits on a live `CameraPreview` that already is the
  /// camera. The matrix demo instead swaps its texture for a video, so its
  /// background is not the camera and has to be drawn.
  ///
  /// Write colour only: the clear has already set depth to 1.0 and the scene
  /// pass depends on that.
  void preRender(Framebuffer fb) {}

  /// A chance to transform the finished framebuffer, before it becomes an
  /// image.
  ///
  /// This is the port of a demo that renders to *texture* and then runs
  /// screen-space passes over the result — celFace blurs the mask's alpha
  /// channel twice and re-tints it. Nothing else here needs it, so it defaults
  /// to a no-op.
  ///
  /// [fb.color] is premultiplied RGBA8888 and may be rewritten in place; the
  /// depth buffer is spent by this point and can be ignored.
  void postProcess(Framebuffer fb) {}

  /// A full-screen image laid over the finished render — casa_de_papel's
  /// `calque.png`, which the demo adds as a screen-space quad with
  /// `renderOrder = 999`.
  ///
  /// It is returned rather than drawn into the framebuffer because it must not
  /// be mirrored: the render is flipped to match a mirrored front-camera
  /// preview, and flipping a decorative frame with it would reverse its
  /// artwork. [JeelizFilterOverlay] paints this above the mirror transform.
  ui.Image? get foreground => null;

  /// Where [foreground] goes. Only meaningful when [foreground] is non-null.
  ForegroundLayout get foregroundLayout => ForegroundLayout.fill;
}
