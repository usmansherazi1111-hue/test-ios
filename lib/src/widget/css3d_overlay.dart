// The CSS3D arm of the library: a tracked widget, not a rendered image.
//
// [JeelizFilterController] runs landmarks through the rasteriser and hands back
// a `ui.Image`. This does the same tracking and hands back a `Matrix4` instead,
// which a `Transform` applies to any child. No framebuffer, no rasteriser, no
// per-pixel work at all — the GPU composites the child at native resolution.
//
// That is the whole point of the CSS3D demos: for a flat sprite, a transformed
// element beats a 3D scene on both cost and sharpness.

import 'package:flutter/widgets.dart';

import '../core/scene.dart';
import '../css3d/css3d_transform.dart';
import '../math/vec_mat.dart';
import '../tracking/detect_state.dart';
import '../tracking/face_filter_helper.dart';
import '../tracking/landmark_adapter.dart';

/// Tracks a face and produces a CSS3D transform for a widget.
class JeelizCss3dController extends ChangeNotifier {
  JeelizCss3dController({
    Css3dSettings settings = const Css3dSettings(),
    JeelizCubeCalibration calibration = const JeelizCubeCalibration(),
    double smoothing = 0.45,
  })  : placer = Css3dPlacer(settings: settings),
        _adapter = LandmarkDetectStateAdapter(
          calibration: calibration,
          smoothing: smoothing,
        ) {
    // The adapter inverts `update_poses` against a camera, so it needs one even
    // though nothing is rendered through it. The DetectState that falls out —
    // window position, window width, head rotation — is a property of the
    // tracker, not of any camera, which is exactly why it transfers to the
    // CSS3D placement unchanged.
    _camera = _helper.createCamera();
  }

  final Css3dPlacer placer;
  final LandmarkDetectStateAdapter _adapter;
  final JeelizFaceFilterHelper _helper = JeelizFaceFilterHelper();
  late final PerspectiveCamera _camera;

  DetectState lastState = DetectState.lost;

  /// Hidden until the first frame arrives.
  Css3dPose _pose = Css3dPose(
    matrix: Mat4.identity(),
    perspective: 0,
    visible: false,
    isMouthOpen: false,
  );

  Css3dPose get pose => _pose;
  bool get isFaceDetected => _pose.visible;
  bool get isMouthOpen => _pose.isMouthOpen;

  bool _disposed = false;

  /// Feed one tracked frame.
  ///
  /// [landmarks] are normalised 0..1 in the upright, un-mirrored source image;
  /// null when no face was found. [overlaySize] is the size of the area the
  /// overlay covers, which is the analogue of the demo's canvas-sized div.
  void feedLandmarks(
    List<Offset>? landmarks,
    Size sourceSize,
    Size overlaySize,
  ) {
    if (_disposed) return;
    if (sourceSize.width <= 0 || sourceSize.height <= 0) return;
    if (overlaySize.width <= 0 || overlaySize.height <= 0) return;

    // The adapter's reference camera has to match the source it is inverting
    // against, same as JeelizFilterController does.
    _helper.updateCamera(
      _camera,
      canvasWidth: sourceSize.width,
      canvasHeight: sourceSize.height,
      videoWidth: sourceSize.width,
      videoHeight: sourceSize.height,
    );

    lastState = _adapter.convert(landmarks, sourceSize, _camera);
    _pose = placer.place(lastState, overlaySize.width, overlaySize.height);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Applies [JeelizCss3dController]'s transform to [child].
///
/// The child is stretched to fill the overlay, mirroring the demo, which sizes
/// its div to the canvas and lets `background-size: cover` do the rest. So for
/// the comedy glasses the child is simply the image with `BoxFit.cover`.
class JeelizCss3dOverlay extends StatelessWidget {
  const JeelizCss3dOverlay({
    super.key,
    required this.controller,
    required this.child,
  });

  final JeelizCss3dController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The overlay's own size is what the placement is computed against, so
        // it is reported back on every layout rather than assumed.
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return _Css3dBody(
            controller: controller, size: size, child: child);
      },
    );
  }
}

class _Css3dBody extends StatefulWidget {
  const _Css3dBody({
    required this.controller,
    required this.size,
    required this.child,
  });

  final JeelizCss3dController controller;
  final Size size;
  final Widget child;

  @override
  State<_Css3dBody> createState() => _Css3dBodyState();
}

class _Css3dBodyState extends State<_Css3dBody> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final pose = widget.controller.pose;
        if (!pose.visible) return const SizedBox.expand();

        final m = Matrix4.zero();
        // Mat4 stores column-major, and so does Matrix4 — a straight copy.
        for (var i = 0; i < 16; i++) {
          m.storage[i] = pose.matrix.m[i];
        }

        return IgnorePointer(
          child: Center(
            child: Transform(
              alignment: Alignment.center,
              transform: m,
              child: SizedBox(
                width: widget.size.width,
                height: widget.size.height,
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The comedy glasses, ready to drop into a [JeelizCss3dOverlay].
///
/// `background-size: cover` on a div the size of the canvas.
class ComedyGlassesImage extends StatelessWidget {
  const ComedyGlassesImage({super.key});

  static const String assetPath = 'assets/comedyGlasses/comedy-glasses.png';
  static const String packagedAssetPath =
      'packages/jeeliz_dart/assets/comedyGlasses/comedy-glasses.png';

  @override
  Widget build(BuildContext context) {
    // Same two-root problem as src/core/assets.dart, but Image cannot probe —
    // so it tries the packaged key and falls back to the bare one.
    return Image.asset(
      packagedAssetPath,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, _, __) => Image.asset(
        assetPath,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, _, __) => const SizedBox.shrink(),
      ),
    );
  }
}
