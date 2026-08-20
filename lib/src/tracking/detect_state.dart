// The tracker/renderer boundary.
//
// This is deliberately the *same* seven numbers Jeeliz's neural net emits, and
// deliberately the only thing the filter code knows about tracking. Swap
// MediaPipe for ARKit, for a real port of Jeeliz's own net, or for a replay of
// recorded values, and nothing downstream changes.

/// One face's tracking result for one frame.
///
/// Coordinates describe the *detection window*: the square the tracker has
/// decided the head occupies, which the renderer treats as the front face of a
/// unit cube.
class DetectState {
  const DetectState({
    required this.detected,
    required this.x,
    required this.y,
    required this.s,
    required this.rx,
    required this.ry,
    required this.rz,
    this.expressions = const [0.0],
  });

  /// Confidence, 0..1. Compared against `detectionThreshold` with hysteresis.
  final double detected;

  /// Centre of the detection window in normalised device coordinates:
  /// -1..1 across the video, **+Y up**.
  final double x, y;

  /// Width of the detection window as a fraction of the video width.
  final double s;

  /// Head rotation in radians. [rx] pitch, [ry] yaw, [rz] roll — applied in
  /// three.js Euler order ZYX.
  final double rx, ry, rz;

  /// Facial expression outputs, 0..1. Index 0 is mouth opening — the tiger
  /// filter reads `detectState.expressions[0]` to swing the jaw and to fire
  /// its particles.
  ///
  /// Jeeliz produces these from a dedicated network (`NN_4EXPR_*.json`).
  /// Landmark trackers have no equivalent output, so
  /// [LandmarkDetectStateAdapter] measures them geometrically instead — see
  /// its `_mouthOpening`.
  final List<double> expressions;

  /// Mouth opening, 0..1. Convenience for the common case.
  double get mouthOpening => expressions.isEmpty ? 0.0 : expressions[0];

  static const lost = DetectState(
      detected: 0, x: 0, y: 0, s: 0.5, rx: 0, ry: 0, rz: 0);

  DetectState lerpTo(DetectState o, double t) => DetectState(
        detected: o.detected,
        x: x + (o.x - x) * t,
        y: y + (o.y - y) * t,
        s: s + (o.s - s) * t,
        rx: rx + (o.rx - rx) * t,
        ry: ry + (o.ry - ry) * t,
        rz: rz + (o.rz - rz) * t,
        expressions: _lerpExpressions(expressions, o.expressions, t),
      );

  static List<double> _lerpExpressions(
      List<double> a, List<double> b, double t) {
    if (a.length != b.length) return b;
    return List<double>.generate(
        b.length, (i) => a[i] + (b[i] - a[i]) * t,
        growable: false);
  }

  @override
  String toString() => 'DetectState(det=${detected.toStringAsFixed(2)} '
      'x=${x.toStringAsFixed(3)} y=${y.toStringAsFixed(3)} '
      's=${s.toStringAsFixed(3)} '
      'rx=${rx.toStringAsFixed(2)} ry=${ry.toStringAsFixed(2)} '
      'rz=${rz.toStringAsFixed(2)} '
      'mouth=${mouthOpening.toStringAsFixed(2)})';
}
