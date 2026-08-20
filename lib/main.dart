// Runnable demo for the ported Jeeliz filters, on the front camera.
//
// This replaces the counter app `flutter create` left here. That file used
// dot-shorthand syntax (`colorScheme: .fromSeed(...)`), which needs a Dart SDK
// constraint of 3.10.0+; against this package's `>=3.0.0` constraint it failed
// to compile, so no root isolate was ever created and the app hung on a blank
// screen ("Could not prepare isolate" in the engine log).

import 'package:camera/camera.dart' show CameraPreview;
import 'package:flutter/material.dart';

import 'demo/landmark_source.dart';
import 'demo/painting_face_locator.dart';
import 'jeeliz_dart.dart';

void main() {
  runApp(const JeelizDemoApp());
}

/// Which port to show. Add a case here and in [_buildFilter] to demo the next
/// one — everything else is shared.
enum DemoFilter {
  glasses,
  tiger,
  casaDePapel,
  rupyHelmet,
  dogFace,
  cloud,
  liberty,
  comedyGlasses,
  artPainting,
  celFace,
  butterflies,
  matrix,
  luffy1,
  luffy2,
  gltfHelmet,
  fireworks,
  spider,
}

extension on DemoFilter {
  String get label => switch (this) {
        DemoFilter.glasses => 'Glasses',
        DemoFilter.tiger => 'Tiger',
        DemoFilter.casaDePapel => 'Casa',
        DemoFilter.rupyHelmet => 'Helmet',
        DemoFilter.dogFace => 'Dog',
        DemoFilter.cloud => 'Cloud',
        DemoFilter.liberty => 'Liberty',
        DemoFilter.comedyGlasses => 'Comedy',
        DemoFilter.artPainting => 'Painting',
        DemoFilter.celFace => 'Cel',
        DemoFilter.butterflies => 'Wings',
        DemoFilter.matrix => 'Matrix',
        DemoFilter.luffy1 => 'Luffy 1',
        DemoFilter.luffy2 => 'Luffy 2',
        DemoFilter.gltfHelmet => 'glTF',
        DemoFilter.fireworks => 'Fireworks',
        DemoFilter.spider => 'Spider',
      };

  /// The CSS3D demo is not a [JeelizFilter] at all — it places a *widget* with
  /// a transform instead of rendering a scene, so it takes a different path
  /// through this page.
  bool get isCss3d => this == DemoFilter.comedyGlasses;

  /// The art-painting swap is a third path again: 2D compositing, no scene and
  /// no widget transform. It also replaces the camera preview rather than
  /// overlaying it — the whole point is that you appear inside the painting.
  bool get isArtPainting => this == DemoFilter.artPainting;

  /// Longest side of the camera texture this filter should get.
  ///
  /// celFace's edge detector reaches exactly one video texel, so its ink gets
  /// thicker and blockier as the texture shrinks. 192 — fine for the tiger,
  /// which only wants a brightness — visibly coarsens the outlines here.
  int get videoDimension => this == DemoFilter.celFace ? 320 : 192;

  /// multiLiberty is the one demo that tracks more than one face
  /// (`maxFaces: 4`). Everything else is single-face.
  int get maxFaces => this == DemoFilter.liberty ? 4 : 1;
}

class JeelizDemoApp extends StatelessWidget {
  const JeelizDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'jeeliz_dart',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF8833),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const FilterDemoPage(),
    );
  }
}

class FilterDemoPage extends StatefulWidget {
  const FilterDemoPage({super.key});

  @override
  State<FilterDemoPage> createState() => _FilterDemoPageState();
}

class _FilterDemoPageState extends State<FilterDemoPage> {
  CameraLandmarkSource? _source;

  JeelizFilterController? _controller;
  JeelizCss3dController? _css3d;
  String? _error;
  bool _cameraReady = false;
  bool _showHud = true;

  DemoFilter _selected = DemoFilter.tiger;
  int _renderDimension = 480;

  /// The preview is mirrored, so the overlay and the tiger's video lookup have
  /// to be mirrored to match.
  static const bool _mirror = true;

  @override
  void initState() {
    super.initState();
    _rebuildController();
    _startSource();
  }

  /// Live only while [DemoFilter.artPainting] is selected.
  ArtPaintingController? _art;
  final PaintingFaceLocator _locator = PaintingFaceLocator();
  int _paintingIndex = 0;
  String? _paintingError;

  /// (Re)starts capture for the current filter's face count.
  ///
  /// The multi-face flow needs `FaceMeshProcessor.createForMultiFace`, which is
  /// chosen at construction — so switching between a single-face filter and
  /// multiLiberty means tearing the camera down and standing it back up.
  void _startSource() {
    final previous = _source;
    previous?.dispose();
    _cameraReady = false;

    final source = CameraLandmarkSource(maxFaces: _selected.maxFaces);
    _source = source;
    source.start((frame) {
      if (!mounted) return;
      final css = _css3d;
      if (css != null) {
        // The overlay covers the whole page, so that is the element size.
        final size = MediaQuery.sizeOf(context);
        css.feedLandmarks(frame.landmarks, frame.sourceSize, size);
        if (!_cameraReady) setState(() => _cameraReady = true);
        return;
      }

      final art = _art;
      if (art != null) {
        // The swap always needs pixels — it is entirely about colour — so
        // there is no `needsVideo` check here.
        final plane = frame.lumaPlane;
        if (plane != null) {
          if (frame.lumaIsInterleaved8888) {
            art.feedInterleaved8888(
              plane,
              frame.lumaWidth,
              frame.lumaHeight,
              rowStride: frame.lumaRowStride,
              rotationDegrees: frame.rotationDegrees,
            );
          } else {
            art.feedLumaPlane(
              plane,
              frame.lumaWidth,
              frame.lumaHeight,
              rowStride: frame.lumaRowStride,
              rotationDegrees: frame.rotationDegrees,
            );
          }
        }
        art.feedLandmarks(frame.landmarks, frame.sourceSize);
        if (!_cameraReady) setState(() => _cameraReady = true);
        return;
      }

      final c = _controller;
      if (c == null) return;

      // Video first: the filter must have this frame's pixels before the
      // render that samples them.
      final plane = frame.lumaPlane;
      if (c.needsVideo && plane != null) {
        if (frame.lumaIsInterleaved8888) {
          c.feedInterleaved8888(
            plane,
            frame.lumaWidth,
            frame.lumaHeight,
            rowStride: frame.lumaRowStride,
            rotationDegrees: frame.rotationDegrees,
          );
        } else {
          c.feedLumaPlane(
            plane,
            frame.lumaWidth,
            frame.lumaHeight,
            rowStride: frame.lumaRowStride,
            rotationDegrees: frame.rotationDegrees,
          );
        }
      }

      if (source.isMultiFace) {
        c.feedMultiFaceLandmarks(frame.faces, frame.sourceSize);
      } else {
        c.feedLandmarks(frame.landmarks, frame.sourceSize);
      }
      if (!_cameraReady) setState(() => _cameraReady = true);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  JeelizFilter _buildFilter() => switch (_selected) {
        DemoFilter.glasses => GlassesFilter(),
        DemoFilter.tiger => TigerFilter(mirrorVideo: _mirror),
        DemoFilter.casaDePapel => CasaDePapelFilter(),
        DemoFilter.rupyHelmet => RupyHelmetFilter(mirrorVideo: _mirror),
        DemoFilter.dogFace => DogFaceFilter(),
        DemoFilter.cloud => CloudFilter(),
        DemoFilter.liberty => MultiLibertyFilter(),
        DemoFilter.celFace => CelFaceFilter(mirrorVideo: _mirror),
        DemoFilter.butterflies => ButterfliesFilter(),
        DemoFilter.matrix => MatrixFilter(mirrorVideo: _mirror),
        DemoFilter.luffy1 => LuffysHatFilter(part: LuffysHatPart.part1),
        DemoFilter.luffy2 =>
          LuffysHatFilter(part: LuffysHatPart.part2, mirrorVideo: _mirror),
        DemoFilter.gltfHelmet => GltfHelmetFilter(),
        DemoFilter.fireworks => FireworksFilter(),
        DemoFilter.spider => HalloweenSpiderFilter(mirrorVideo: _mirror),
        // Never rendered — the CSS3D and art-painting paths both bypass the
        // rasteriser entirely.
        DemoFilter.comedyGlasses => GlassesFilter(),
        DemoFilter.artPainting => GlassesFilter(),
      };

  CasaDePapelFilter? get _casa {
    final f = _controller?.filter;
    return f is CasaDePapelFilter ? f : null;
  }

  RupyHelmetFilter? get _helmet {
    final f = _controller?.filter;
    return f is RupyHelmetFilter ? f : null;
  }

  DogFaceFilter? get _dog {
    final f = _controller?.filter;
    return f is DogFaceFilter ? f : null;
  }

  LuffysHatFilter? get _luffy {
    final f = _controller?.filter;
    return f is LuffysHatFilter && f.isDraggable ? f : null;
  }

  /// Both casa_de_papel and rupy_helmet call `addDragEventListener` so the
  /// wearer can nudge the model onto their face.
  bool get _isDraggable =>
      _casa != null || _helmet != null || _dog != null || _luffy != null;

  void _drag(Offset delta) {
    const k = 0.006; // pixels -> face-object units
    // X is negated because the preview is mirrored.
    final d = Vec3(-delta.dx * k, -delta.dy * k, 0);
    final casa = _casa;
    if (casa != null) casa.maskOffset = casa.maskOffset + d;
    final helmet = _helmet;
    if (helmet != null) helmet.offset = helmet.offset + d;
    final dog = _dog;
    if (dog != null) dog.offset = dog.offset + d;
    final luffy = _luffy;
    if (luffy != null) luffy.offset = luffy.offset + d;
  }

  void _recentre() {
    _casa?.maskOffset = Vec3.zero;
    _helmet?.offset = Vec3.zero;
    _dog?.offset = Vec3.zero;
    _luffy?.offset = Vec3.zero;
  }

  void _rebuildController() {
    final previousCss = _css3d;
    final previous = _controller;
    final previousArt = _art;

    if (_selected.isArtPainting) {
      _css3d = null;
      _controller = null;
      _art = ArtPaintingController(mirror: _mirror);
      _loadPainting(_paintingIndex);
    } else if (_selected.isCss3d) {
      // No scene, no rasteriser — just tracking plus a transform.
      _css3d = JeelizCss3dController();
      _controller = null;
    } else {
      _css3d = null;
      _art = null;
      // Built first, because a filter may ask for a different tracking pivot —
      // luffys_hat_part2 calls `set_pivotOffsetYZ` before init, and that is a
      // helper setting, not something the scene graph can express.
      final filter = _buildFilter();
      _controller = JeelizFilterController(
        filter: filter,
        settings: JeelizHelperSettings(
          pivotOffsetYZ: filter.preferredPivotOffsetYZ ??
              const JeelizHelperSettings().pivotOffsetYZ,
        ),
        maxFaces: _selected.maxFaces,
        maxRenderDimension: _renderDimension,
        videoLumaDimension: _selected.videoDimension,
      )..load();
    }

    previous?.dispose();
    previousCss?.dispose();
    previousArt?.dispose();
  }

  /// Loads painting [index], finding its face first.
  ///
  /// The locate step is what the demo spends its first few seconds on; here it
  /// is one MediaPipe pass, cached per painting.
  Future<void> _loadPainting(int index) async {
    final art = _art;
    if (art == null) return;
    final key = kArtPaintings[index % kArtPaintings.length];
    setState(() => _paintingError = null);

    final face = await _locator.locate(key);
    if (!mounted || _art != art) return;
    if (face.detected <= 0) {
      // The demo alerts 'FACE NOT FOUND' and stops; a message is friendlier.
      setState(() => _paintingError = 'No face found in ${_shortName(key)}');
      return;
    }
    await art.loadPainting(key, face);
  }

  static String _shortName(String assetKey) =>
      assetKey.split('/').last.replaceAll('.jpg', '');

  @override
  void dispose() {
    _source?.dispose();
    _controller?.dispose();
    _css3d?.dispose();
    _art?.dispose();
    _locator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: _controls(),
            ),
          ),
          if (_showHud && _controller != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _Hud(controller: _controller!, filter: _selected),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _preview() {
    final err = _error;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Camera failed:\n\n$err',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFE8B4BC)),
          ),
        ),
      );
    }

    final art = _art;
    if (art != null) return _artPreview(art);

    final cam = _source?.controller;
    final controller = _controller;
    final css = _css3d;
    if (!_cameraReady ||
        cam == null ||
        !cam.value.isInitialized ||
        (controller == null && css == null)) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final p = cam.value.previewSize;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (p != null)
          FittedBox(
            fit: BoxFit.cover,
            // previewSize is landscape-oriented; swap for a portrait preview.
            child: SizedBox(
                width: p.height, height: p.width, child: CameraPreview(cam)),
          ),
        if (controller != null)
          JeelizFilterOverlay(controller: controller, mirror: _mirror)
        else if (css != null)
          JeelizCss3dOverlay(
            controller: css,
            child: const ComedyGlassesImage(),
          ),
        // `addDragEventListener(...)` in the originals.
        if (_isDraggable)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (d) => _drag(d.delta),
            onDoubleTap: _recentre,
          ),
      ],
    );
  }

  /// The painting fills the screen; the camera is never shown, only sampled.
  Widget _artPreview(ArtPaintingController art) {
    final err = _paintingError;
    if (err != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(err,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFE8B4BC))),
        ),
      );
    }
    return AnimatedBuilder(
      animation: art,
      builder: (context, _) {
        if (!art.isLoaded) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        return Center(child: ArtPaintingView(controller: art));
      },
    );
  }

  Widget _controls() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<DemoFilter>(
            segments: [
              for (final f in DemoFilter.values)
                ButtonSegment(value: f, label: Text(f.label)),
            ],
            selected: {_selected},
            onSelectionChanged: (s) {
              final was = _selected.maxFaces;
              setState(() {
                _selected = s.first;
                _rebuildController();
              });
              // Only restart the camera when the face count actually changes;
              // it costs a visible beat.
              if (_selected.maxFaces != was) _startSource();
            },
          ),
          if (_art != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(() {
                    _paintingIndex =
                        (_paintingIndex - 1) % kArtPaintings.length;
                    if (_paintingIndex < 0) {
                      _paintingIndex += kArtPaintings.length;
                    }
                    _loadPainting(_paintingIndex);
                  }),
                ),
                SizedBox(
                  width: 150,
                  child: Text(
                    _shortName(kArtPaintings[_paintingIndex]),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => setState(() {
                    _paintingIndex =
                        (_paintingIndex + 1) % kArtPaintings.length;
                    _loadPainting(_paintingIndex);
                  }),
                ),
              ],
            ),
          ] else if (_casa != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.tonal(
                  onPressed: () {
                    final casa = _casa;
                    if (casa == null) return;
                    setState(() =>
                        casa.isRunning ? casa.reset() : casa.startHeist());
                  },
                  child: Text(_casa!.isRunning ? 'Stop' : 'Bella Ciao'),
                ),
                const SizedBox(width: 10),
                const Text('drag to fit · 2-tap to centre',
                    style: TextStyle(fontSize: 10)),
              ],
            ),
          ] else if (_isDraggable) ...[
            const SizedBox(height: 6),
            Text(
              _dog != null
                  ? 'drag to fit · 2-tap to centre · open mouth for tongue'
                  : 'drag to fit · 2-tap to centre',
              style: const TextStyle(fontSize: 10),
            ),
          ],
          if (_selected == DemoFilter.spider) ...[
            const SizedBox(height: 6),
            const Text('open your mouth', style: TextStyle(fontSize: 10)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Render', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: _renderDimension.toDouble(),
                  min: 240,
                  max: 960,
                  divisions: 12,
                  label: '$_renderDimension px',
                  onChanged: (v) =>
                      setState(() => _renderDimension = (v ~/ 60) * 60),
                  onChangeEnd: (_) => setState(_rebuildController),
                ),
              ),
              SizedBox(
                width: 46,
                child: Text('$_renderDimension',
                    style: const TextStyle(fontSize: 12)),
              ),
              IconButton(
                icon: Icon(_showHud ? Icons.info : Icons.info_outline),
                onPressed: () => setState(() => _showHud = !_showHud),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({required this.controller, required this.filter});

  final JeelizFilterController controller;
  final DemoFilter filter;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final err = controller.loadError;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            err != null
                ? 'ASSET LOAD FAILED\n$err'
                : 'jeeliz_dart · ${filter.label}\n'
                    '${controller.isLoaded ? "assets ok" : "loading assets…"}\n'
                    '${controller.isFaceDetected ? "face: tracked" : "face: none"}\n'
                    '${controller.lastState}\n'
                    '${controller.stats}',
            style: const TextStyle(
                color: Colors.white, fontSize: 10, height: 1.45),
          ),
        );
      },
    );
  }
}
