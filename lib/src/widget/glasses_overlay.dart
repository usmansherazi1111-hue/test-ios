// Glasses-shaped convenience over the generic controller.
//
// The glassesVTO port landed before there was more than one filter, so the
// controller was glasses-specific. It is not any more — see
// [JeelizFilterController]. These two names stay so existing call sites keep
// working, and because "give me the glasses filter" is a genuinely common
// thing to want.

import '../filters/glasses_vto.dart';
import 'filter_overlay.dart';

class JeelizGlassesController extends JeelizFilterController {
  JeelizGlassesController({
    super.settings,
    super.calibration,
    GlassesFrameModel frameModel = GlassesFrameModel.branchesBent,
    int envMapWidth = 512,
    super.maxRenderDimension,
    super.smoothing,
  }) : super(
          filter: GlassesFilter(
              frameModel: frameModel, envMapWidth: envMapWidth),
        );

  GlassesFilter get glasses => filter as GlassesFilter;

  /// The loaded meshes and materials, once [load] has completed. Exposed so a
  /// caller can retint the frames or lenses at runtime.
  GlassesAssets? get assets => glasses.assets;
}

/// Alias of [JeelizFilterOverlay]; the overlay was never glasses-specific.
class JeelizGlassesOverlay extends JeelizFilterOverlay {
  const JeelizGlassesOverlay({
    super.key,
    required super.controller,
    super.fit,
    super.mirror,
  });
}
