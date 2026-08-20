// Finds where a painting's own face is, so the swap knows where to cut.
//
// The demo does this by feeding the still image to the CNN over and over and
// averaging 25 positive detections, because its detector is a video tracker
// with no still-image entry point. MediaPipe has one, so a single pass is
// enough — but the *result* has to mean the same thing, which is why it goes
// through `ArtPaintingController.locateFace` and comes out as a `DetectState`
// exactly like a camera frame's.
//
// This lives in demo/ rather than src/ for the same reason the camera source
// does: it depends on a specific ML package, and the library must not.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset, Size;
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

import '../src/core/assets.dart';
import '../src/faceswap/art_painting_controller.dart';
import '../src/tracking/detect_state.dart';

/// Runs FaceMesh once over a still image and reports where its face is.
///
/// Reuses one processor across calls — building it is the expensive part, and
/// a painting picker will call this for each painting the user tries.
class PaintingFaceLocator {
  FaceMeshProcessor? _mesh;
  FaceDetectorProcessor? _detector;
  FaceMeshInferencePipeline? _inference;
  bool _disposed = false;

  final Map<String, DetectState> _cache = <String, DetectState>{};

  Future<void> _ensure() async {
    if (_inference != null || _disposed) return;
    _detector = await FaceDetectorProcessor.create();
    _mesh = await FaceMeshProcessor.create(enableAttentionMesh: true);
    _inference = FaceMeshInferencePipeline(
      detector: _detector!,
      mesh: _mesh!,
      // No smoothing: there is exactly one frame, and a smoother would only
      // damp the single measurement towards its own initial state.
      landmarkSmoothing: null,
    );
  }

  /// Locates the face in the painting at [assetRelative].
  ///
  /// Returns [DetectState.lost] if no face is found, which the caller should
  /// treat as "this painting cannot be used" — the demo shows an alert in the
  /// same situation.
  ///
  /// The Mona Lisa short-circuits to [kJocondeFace], the state the demo
  /// hard-codes to skip its own search.
  Future<DetectState> locate(String assetRelative) async {
    if (assetRelative.endsWith('Joconde.jpg')) return kJocondeFace;
    final cached = _cache[assetRelative];
    if (cached != null) return cached;

    try {
      await _ensure();
      if (_disposed) return DetectState.lost;

      final bytes = await loadJeelizAssetUint8List(assetRelative);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      codec.dispose();

      final w = image.width, h = image.height;
      final rgba =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (rgba == null) return DetectState.lost;

      final state = _solve(rgba.buffer.asUint8List(), w, h);
      _cache[assetRelative] = state;
      return state;
    } catch (e, st) {
      debugPrint('PaintingFaceLocator.locate($assetRelative) failed: $e\n$st');
      return DetectState.lost;
    }
  }

  DetectState _solve(Uint8List rgba, int w, int h) {
    // `rawRgba` is R,G,B,A; FaceMeshPixelFormat.bgra wants the first two
    // channels swapped. Swapping in place is fine — the buffer is a copy.
    for (var i = 0; i < rgba.length; i += 4) {
      final r = rgba[i];
      rgba[i] = rgba[i + 2];
      rgba[i + 2] = r;
    }

    final result = _inference!.process(
      FaceMeshImage(
        pixels: rgba,
        width: w,
        height: h,
        pixelFormat: FaceMeshPixelFormat.bgra,
        bytesPerRow: w * 4,
      ),
      rotationDegrees: 0,
    );

    final mesh = result.meshResult;
    if (mesh == null) return DetectState.lost;

    final landmarks =
        mesh.landmarks.map((p) => Offset(p.x, p.y)).toList(growable: false);
    return ArtPaintingController.locateFace(
        landmarks, Size(w.toDouble(), h.toDouble()));
  }

  void dispose() {
    _disposed = true;
    _inference = null;
    _detector?.close();
    _mesh?.close();
    _mesh = null;
    _detector = null;
  }
}
