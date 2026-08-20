// Controller + widget for the art-painting face swap.
//
// Unlike every other filter here this one never touches the rasteriser: the
// output is two images drawn on top of each other, so a CustomPainter is the
// whole renderer. The controller's job is to hold the prepared painting, turn
// each tracked frame into a recoloured face crop, and expose both.
//
// The library still knows nothing about cameras or ML. Landmarks come in the
// same way as for every other filter; the painting's own face is supplied by
// the caller as a `DetectState`, which is the point where a still-image
// detector plugs in.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/assets.dart';
import '../core/scene.dart';
import '../core/video_texture.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import '../tracking/landmark_adapter.dart';
import 'art_painting.dart';
import 'face_swap.dart';

/// The demo's hard-coded answer for `images/Joconde.jpg`:
///
/// ```js
/// detectState: {x:-0.09803, y:0.44314, s:0.18782, ry:-0.04926}
/// ```
///
/// It exists so the initial painting skips the 25-detection search. Any other
/// painting has to be located, which is what [ArtPaintingController.locateFace]
/// is for.
const DetectState kJocondeFace = DetectState(
  detected: 1,
  x: -0.09803,
  y: 0.44314,
  s: 0.18782,
  rx: 0,
  ry: -0.04926,
  rz: 0,
);

/// The ten paintings and posters shipped with the demo, as asset-relative keys.
const List<String> kArtPaintings = <String>[
  'artPainting/Joconde.jpg',
  'artPainting/louis14.jpg',
  'artPainting/liberty.jpg',
  'artPainting/captainAmerica.jpg',
  'artPainting/cosmopolitan.jpg',
  'artPainting/doors.jpg',
  'artPainting/pirates_of_the_caribbean.jpg',
  'artPainting/starTrek.jpg',
  'artPainting/terminator.jpg',
  'artPainting/will_smith.jpg',
];

/// Drives the art-painting swap: holds one prepared painting, and produces a
/// recoloured face crop per tracked frame.
class ArtPaintingController extends ChangeNotifier {
  ArtPaintingController({
    this.settings = const ArtPaintingSettings(),
    JeelizHelperSettings helperSettings = const JeelizHelperSettings(),
    JeelizCubeCalibration calibration = const JeelizCubeCalibration(),
    double smoothing = 0.45,
    this.videoDimension = 256,
    this.paintingMaxWidth = 1024,
    this.mirror = true,
  })  : _helper = JeelizFaceFilterHelper(settings: helperSettings),
        _adapter = LandmarkDetectStateAdapter(
          calibration: calibration,
          pivotOffsetYZ: helperSettings.pivotOffsetYZ,
          smoothing: smoothing,
        ) {
    _camera = _helper.createCamera();
  }

  final ArtPaintingSettings settings;

  /// Longest side of the camera colour texture the crop samples from.
  ///
  /// The crop is 256px square, so sampling a much larger video buys nothing —
  /// and this one genuinely needs colour, which costs a YUV conversion per
  /// frame.
  final int videoDimension;

  /// Longest side the painting is decoded at. Full-resolution JPEGs would make
  /// the one-off mask pass slow for no visible gain.
  final int paintingMaxWidth;

  /// Whether the camera feed is mirrored, as a selfie preview is.
  final bool mirror;

  final JeelizFaceFilterHelper _helper;
  final LandmarkDetectStateAdapter _adapter;
  late final PerspectiveCamera _camera;

  late final VideoLumaSampler _sampler =
      VideoLumaSampler(maxDimension: videoDimension, color: true);
  late final FaceSwapCompositor _compositor =
      FaceSwapCompositor(settings: settings);

  VideoLumaTexture? _video;
  ArtPainting? _painting;
  ui.Image? _face;
  DetectState _state = DetectState.lost;
  bool _busy = false;
  bool _disposed = false;
  String? _key;

  Object? loadError;

  /// The prepared painting, or null before [loadPainting] finishes.
  ArtPainting? get painting => _painting;

  /// The asset key of the loaded painting.
  String? get paintingKey => _key;

  /// The most recent recoloured face crop. Owned by the controller.
  ui.Image? get faceImage => _face;

  DetectState get lastState => _state;
  bool get isFaceDetected => _state.detected > 0;
  bool get isLoaded => _painting != null;

  /// The camera used to solve poses — needed to locate a painting's face with
  /// [locateFace].
  PerspectiveCamera get camera => _camera;

  /// Prepares a painting: decode it, cut the head-shaped hole, and reduce the
  /// face that was there to its colour signature.
  ///
  /// [paintingFace] is where the painting's own face is. Pass [kJocondeFace]
  /// for the Mona Lisa; for anything else, run a detector over the decoded
  /// image and convert the result with [locateFace].
  Future<void> loadPainting(String assetRelative, DetectState paintingFace) async {
    loadError = null;
    try {
      final bytes = await loadJeelizAssetUint8List(assetRelative);
      if (_disposed) return;
      final built = await buildArtPainting(
        encodedImage: bytes,
        paintingFace: paintingFace,
        settings: settings,
        maxWidth: paintingMaxWidth,
      );
      if (_disposed) {
        built.dispose();
        return;
      }
      _painting?.dispose();
      _painting = built;
      _key = assetRelative;
      _dropFace();
      notifyListeners();
    } catch (e, st) {
      loadError = e;
      debugPrint('ArtPaintingController.loadPainting failed: $e\n$st');
      if (!_disposed) notifyListeners();
    }
  }

  /// Turns landmarks found in a *still image* into the `DetectState` that
  /// [loadPainting] wants.
  ///
  /// This is the still-image counterpart of [feedLandmarks], and the seam where
  /// a face detector plugs in: decode the painting, run whatever tracker the
  /// app already has over it, hand the landmarks here. It uses a throwaway
  /// adapter so the live tracking state is left alone, and no smoothing,
  /// because there is only ever one frame.
  ///
  /// Returns [DetectState.lost] when [landmarks] is null.
  static DetectState locateFace(
    List<Offset>? landmarks,
    Size imageSize, {
    JeelizHelperSettings helperSettings = const JeelizHelperSettings(),
    JeelizCubeCalibration calibration = const JeelizCubeCalibration(),
  }) {
    if (landmarks == null || landmarks.isEmpty) return DetectState.lost;
    final helper = JeelizFaceFilterHelper(settings: helperSettings);
    final camera = helper.createCamera();
    helper.updateCamera(
      camera,
      canvasWidth: imageSize.width,
      canvasHeight: imageSize.height,
      videoWidth: imageSize.width,
      videoHeight: imageSize.height,
    );
    final adapter = LandmarkDetectStateAdapter(
      calibration: calibration,
      pivotOffsetYZ: helperSettings.pivotOffsetYZ,
      smoothing: 0,
    );
    return adapter.convert(landmarks, imageSize, camera);
  }

  /// Hands over the camera's luma+chroma planes. Call before [feedLandmarks].
  void feedLumaPlane(
    Uint8List plane,
    int width,
    int height, {
    required int rowStride,
    int rotationDegrees = 0,
  }) {
    if (_disposed) return;
    try {
      _video = _sampler.fromLumaPlane(
        plane,
        width,
        height,
        rowStride: rowStride,
        rotation: videoRotationFromDegrees(rotationDegrees),
      );
    } catch (e) {
      debugPrint('ArtPaintingController.feedLumaPlane failed: $e');
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
    if (_disposed) return;
    try {
      _video = _sampler.fromInterleaved8888(
        pixels,
        width,
        height,
        rowStride: rowStride,
        bgra: bgra,
        rotation: videoRotationFromDegrees(rotationDegrees),
      );
    } catch (e) {
      debugPrint('ArtPaintingController.feedInterleaved8888 failed: $e');
    }
  }

  /// Feed one tracked frame. [landmarks] are normalised 0..1 in the upright,
  /// un-mirrored source image; null when no face was found.
  Future<void> feedLandmarks(List<Offset>? landmarks, Size sourceSize) async {
    if (_disposed || _busy) return;
    final painting = _painting;
    final video = _video;
    if (painting == null || video == null) return;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) return;

    _busy = true;
    try {
      _helper.updateCamera(
        _camera,
        canvasWidth: sourceSize.width,
        canvasHeight: sourceSize.height,
        videoWidth: sourceSize.width,
        videoHeight: sourceSize.height,
      );
      _state = _adapter.convert(landmarks, sourceSize, _camera);

      if (_state.detected <= 0) {
        // Nothing to draw. The painting keeps its hole — the demo does the
        // same, showing the cut-out until a face comes back.
        if (_face != null) {
          _dropFace();
          notifyListeners();
        }
        return;
      }

      final rgba = _compositor.cropAndRecolour(
        video: video,
        state: _state,
        painting: painting,
        mirror: mirror,
      );
      if (rgba == null) return;

      final img = await _compositor.toImage(rgba);
      if (_disposed) {
        img.dispose();
        return;
      }
      _face?.dispose();
      _face = img;
      notifyListeners();
    } catch (e, st) {
      debugPrint('ArtPaintingController.feedLandmarks failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  void _dropFace() {
    _face?.dispose();
    _face = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _dropFace();
    _painting?.dispose();
    _painting = null;
    super.dispose();
  }
}

/// Draws the painting with the user's face behind its hole.
///
/// Sized by the painting's own aspect ratio, so drop it in a `Center` or give
/// it bounded constraints and it will letterbox itself.
class ArtPaintingView extends StatelessWidget {
  const ArtPaintingView({
    super.key,
    required this.controller,
    this.showFace = true,
  });

  final ArtPaintingController controller;

  /// Set false to see the hole — useful when tuning the mask.
  final bool showFace;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final painting = controller.painting;
        if (painting == null) {
          return const SizedBox.shrink();
        }
        return AspectRatio(
          aspectRatio: painting.width / painting.height,
          child: CustomPaint(
            painter: _ArtPaintingPainter(
              painting: painting,
              face: showFace ? controller.faceImage : null,
            ),
          ),
        );
      },
    );
  }
}

class _ArtPaintingPainter extends CustomPainter {
  _ArtPaintingPainter({required this.painting, required this.face});

  final ArtPainting painting;
  final ui.Image? face;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.medium;

    // The face first, into the *painting's* box — the user's box only decided
    // what to cut, not where it lands. This is `position_userCropCanvas()`,
    // which places the crop canvas at the painting's face rectangle.
    final f = face;
    if (f != null) {
      final box = painting.box;
      final dst = Rect.fromLTWH(
        box.left * size.width,
        box.topFlipped * size.height,
        box.sxn * size.width,
        box.syn * size.height,
      );
      canvas.drawImageRect(
        f,
        Rect.fromLTWH(0, 0, f.width.toDouble(), f.height.toDouble()),
        dst,
        paint,
      );
    }

    // Then the holed painting over it.
    canvas.drawImageRect(
      painting.image,
      Rect.fromLTWH(
          0, 0, painting.image.width.toDouble(), painting.image.height.toDouble()),
      Offset.zero & size,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ArtPaintingPainter old) =>
      old.painting != painting || old.face != face;
}
