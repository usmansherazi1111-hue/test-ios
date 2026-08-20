// The Flutter end of the pipeline.
//
// Kept free of any camera or ML dependency on purpose: the host app already
// runs a tracker, and coupling this package to one particular plugin would
// make it useless to the next app. Push landmarks in with [feedLandmarks];
// a `ui.Image` comes out.
//
// This is also where the demos' full-screen video quad goes. three renders the
// camera frame as geometry underneath the scene because it shares one WebGL
// canvas; in Flutter the preview is already a widget, so the overlay just
// composites on top of it with the same fit.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../core/scene.dart';
import '../core/video_texture.dart';
import '../filters/filter.dart';
import '../render/renderer.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import '../tracking/landmark_adapter.dart';

/// Owns the scene, the tracking adapter and the rasteriser for one filter.
class JeelizFilterController extends ChangeNotifier {
  JeelizFilterController({
    required this.filter,
    JeelizHelperSettings settings = const JeelizHelperSettings(),
    JeelizCubeCalibration calibration = const JeelizCubeCalibration(),
    int maxFaces = 1,
    this.maxRenderDimension = 480,
    this.videoLumaDimension = 192,
    double smoothing = 0.45,
  })  : helper = JeelizFaceFilterHelper(
            maxFacesDetected: maxFaces < 1 ? 1 : maxFaces,
            settings: settings),
        // One adapter per face slot: each carries its own smoothing state and
        // lost-tracking hold, so sharing one across faces would make them drag
        // each other around.
        adapters = List<LandmarkDetectStateAdapter>.generate(
          maxFaces < 1 ? 1 : maxFaces,
          (_) => LandmarkDetectStateAdapter(
            calibration: calibration,
            pivotOffsetYZ: settings.pivotOffsetYZ,
            smoothing: smoothing,
          ),
          growable: false,
        ) {
    camera = helper.createCamera();
  }

  final JeelizFilter filter;
  final JeelizFaceFilterHelper helper;

  /// One per tracked face slot.
  final List<LandmarkDetectStateAdapter> adapters;

  /// The first slot's adapter — the single-face case, which is most of them.
  LandmarkDetectStateAdapter get adapter => adapters.first;

  /// How many faces this controller tracks at once.
  int get maxFaces => adapters.length;

  /// Longest side of the render target, in pixels.
  ///
  /// This is the single knob that trades fidelity for CPU. The rasteriser is
  /// pure Dart, so cost scales with covered area — 480 keeps a phone
  /// comfortably inside a camera frame's budget, and the result is upscaled by
  /// the GPU on composite, where a little softness is invisible.
  final int maxRenderDimension;

  /// Longest side of the camera-luma texture, for filters that sample the
  /// video (the tiger does; the glasses do not).
  final int videoLumaDimension;

  late final PerspectiveCamera camera;
  final SoftwareRenderer renderer = SoftwareRenderer();

  late final VideoLumaSampler _lumaSampler = VideoLumaSampler(
    maxDimension: videoLumaDimension,
    color: filter.needsVideoColor,
  );

  Framebuffer? _fb;
  ui.Image? _image;
  bool _busy = false;
  bool _disposed = false;
  bool _loaded = false;
  int _lastFrameMicros = 0;

  Object? loadError;

  /// Tracking state per face slot, parallel to [adapters].
  late List<DetectState> lastStates =
      List<DetectState>.filled(adapters.length, DetectState.lost);

  /// The first slot's state — the single-face case.
  DetectState get lastState => lastStates.first;

  /// The most recent overlay. Owned by the controller — do not dispose it.
  ui.Image? get image => _image;

  bool get isLoaded => _loaded;
  bool get isFaceDetected => helper.isDetected;
  RenderStats get stats => renderer.stats;

  /// True when the active filter wants camera pixels. Capture code can skip
  /// the luma pass entirely when this is false.
  bool get needsVideo => filter.needsVideo;

  Future<void> load() async {
    try {
      await filter.load();
      if (_disposed) return;
      filter.attach(helper);
      _loaded = true;
      notifyListeners();
    } catch (e, st) {
      loadError = e;
      debugPrint('JeelizFilterController.load failed: $e\n$st');
      if (!_disposed) notifyListeners();
    }
  }

  /// Hands over the camera's luma plane for filters that sample the video.
  ///
  /// Call this *before* [feedLandmarks] for the same frame. [rotationDegrees]
  /// is what it takes to bring the buffer upright — the same value passed to
  /// the landmark tracker.
  void feedLumaPlane(
    Uint8List plane,
    int width,
    int height, {
    required int rowStride,
    int rotationDegrees = 0,
  }) {
    if (_disposed || !filter.needsVideo) return;
    try {
      final tex = _lumaSampler.fromLumaPlane(
        plane,
        width,
        height,
        rowStride: rowStride,
        rotation: videoRotationFromDegrees(rotationDegrees),
      );
      filter.setVideo(tex);
    } catch (e) {
      debugPrint('JeelizFilterController.feedLumaPlane failed: $e');
    }
  }

  /// As [feedLumaPlane], but for an interleaved 8888 buffer (iOS BGRA).
  void feedInterleaved8888(
    Uint8List pixels,
    int width,
    int height, {
    required int rowStride,
    bool bgra = true,
    int rotationDegrees = 0,
  }) {
    if (_disposed || !filter.needsVideo) return;
    try {
      final tex = _lumaSampler.fromInterleaved8888(
        pixels,
        width,
        height,
        rowStride: rowStride,
        bgra: bgra,
        rotation: videoRotationFromDegrees(rotationDegrees),
      );
      filter.setVideo(tex);
    } catch (e) {
      debugPrint('JeelizFilterController.feedInterleaved8888 failed: $e');
    }
  }

  /// Feed one tracked frame.
  ///
  /// [landmarks] are normalised 0..1 in the **upright, un-mirrored** source
  /// image; pass null when the tracker found no face. [sourceSize] is that
  /// same image's pixel size.
  ///
  /// Frames arriving while a render is in flight are dropped rather than
  /// queued — the newest pose is always the one worth drawing.
  Future<void> feedLandmarks(List<Offset>? landmarks, Size sourceSize) =>
      feedMultiFaceLandmarks(<List<Offset>?>[landmarks], sourceSize);

  /// Feed one frame carrying up to [maxFaces] tracked faces.
  ///
  /// Entries beyond [maxFaces] are ignored; missing ones count as "no face" for
  /// that slot, which lets its adapter run its own hold-then-drop.
  ///
  /// Slot assignment is the caller's: pass faces in a stable order (a tracker
  /// with persistent ids, for instance) or the filters attached to each slot
  /// will swap heads between frames.
  Future<void> feedMultiFaceLandmarks(
      List<List<Offset>?> facesLandmarks, Size sourceSize) async {
    if (_disposed || !_loaded || _busy) return;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) return;
    _busy = true;
    try {
      final fb = _framebufferFor(sourceSize);

      // Canvas and video share an aspect ratio, so scaleW is 1 and the view
      // offset degenerates — the widget's BoxFit does the cropping instead.
      helper.updateCamera(
        camera,
        canvasWidth: fb.width.toDouble(),
        canvasHeight: fb.height.toDouble(),
        videoWidth: sourceSize.width,
        videoHeight: sourceSize.height,
      );

      lastStates = List<DetectState>.generate(
        adapters.length,
        (i) => adapters[i].convert(
            i < facesLandmarks.length ? facesLandmarks[i] : null,
            sourceSize,
            camera),
        growable: false,
      );
      helper.update(lastStates, camera);

      final now = DateTime.now().microsecondsSinceEpoch;
      final dt = _lastFrameMicros == 0
          ? 1 / 30
          : (now - _lastFrameMicros) / 1e6;
      _lastFrameMicros = now;
      // A backgrounded app can produce an enormous gap; clamping stops
      // particles teleporting through their whole flight in one step.
      // Filters see the first slot's state; multi-face ones read
      // `helper.faceObjects` directly, which is already posed.
      filter.update(lastStates.first, dt.clamp(0.0, 0.25));

      fb.clear();
      filter.preRender(fb);
      // Always render, even with no face. `helper.detect` hides the face
      // object when tracking is lost, so face-attached content disappears on
      // its own — but a filter may also own world-space content that should
      // keep going regardless, as casa_de_papel's falling bills do. Walking an
      // effectively empty scene costs nothing.
      renderer.render(helper.scene, camera, fb);

      // Screen-space passes over the finished buffer — the render-to-texture
      // chains some demos build. A no-op for all but celFace.
      filter.postProcess(fb);

      final img = await fb.toImage();
      if (_disposed) {
        img.dispose();
        return;
      }
      _image?.dispose();
      _image = img;
      notifyListeners();
    } catch (e, st) {
      debugPrint('JeelizFilterController.feedLandmarks failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  Framebuffer _framebufferFor(Size source) {
    final aspect = source.width / source.height;
    int w, h;
    if (aspect >= 1) {
      w = maxRenderDimension;
      h = (maxRenderDimension / aspect).round();
    } else {
      h = maxRenderDimension;
      w = (maxRenderDimension * aspect).round();
    }
    if (w < 2) w = 2;
    if (h < 2) h = 2;

    final existing = _fb;
    if (existing != null && existing.width == w && existing.height == h) {
      return existing;
    }
    return _fb = Framebuffer(w, h);
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    super.dispose();
  }
}

/// Paints the controller's overlay.
///
/// [fit] and [mirror] must match whatever the camera preview underneath is
/// doing, or the filter will float away from the face. A front camera is
/// normally previewed mirrored, so [mirror] defaults accordingly at the call
/// site rather than here.
class JeelizFilterOverlay extends StatelessWidget {
  const JeelizFilterOverlay({
    super.key,
    required this.controller,
    this.fit = BoxFit.cover,
    this.mirror = false,
  });

  final JeelizFilterController controller;
  final BoxFit fit;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final img = controller.image;
        final fg = controller.filter.foreground;
        if (img == null && fg == null) return const SizedBox.expand();

        Widget? render;
        if (img != null) {
          render = SizedBox.expand(
            child: FittedBox(
              fit: fit,
              child: SizedBox(
                width: img.width.toDouble(),
                height: img.height.toDouble(),
                child: CustomPaint(painter: _ImagePainter(img)),
              ),
            ),
          );
          if (mirror) {
            render = Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()..scaleByDouble(-1.0, 1.0, 1.0, 1.0),
              child: render,
            );
          }
        }

        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (render != null) render,
              // Outside the mirror transform on purpose — a decorative frame
              // reversed left-to-right reads as broken. BoxFit.fill matches
              // the original, whose screen-space quad stretches the texture
              // across the whole canvas whatever its aspect ratio.
              if (fg != null)
                SizedBox.expand(
                  child: CustomPaint(
                    painter: _ImagePainter(
                      fg,
                      layout: controller.filter.foregroundLayout,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.image, {this.layout = ForegroundLayout.fill});
  final ui.Image image;
  final ForegroundLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final Rect dst;
    switch (layout) {
      case ForegroundLayout.fill:
        dst = Rect.fromLTWH(0, 0, size.width, size.height);
      case ForegroundLayout.bottomVmin:
        // `width: 100vmin`, natural aspect, `bottom: -5px` on a 600px canvas.
        final width = math.min(size.width, size.height);
        final height = width * h / w;
        final bottom = size.height + 5.0 * size.height / 600.0;
        dst = Rect.fromLTWH(
            (size.width - width) / 2, bottom - height, width, height);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w, h),
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_ImagePainter old) => !identical(old.image, image);
}
