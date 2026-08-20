// Camera capture + FaceMesh inference for the demo app.
//
// Demo-only. Deliberately *not* part of the library: nothing under lib/src/
// imports a camera or an ML plugin, which is what lets the port be driven by
// any tracker. This file exists so `flutter run` in this directory shows
// something, and it is the piece a host app replaces with its own capture.

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

class LandmarkFrame {
  const LandmarkFrame(
    this.landmarks,
    this.sourceSize, {
    this.faces = const [],
    this.lumaPlane,
    this.lumaWidth = 0,
    this.lumaHeight = 0,
    this.lumaRowStride = 0,
    this.rotationDegrees = 0,
    this.lumaIsInterleaved8888 = false,
  });

  /// Normalised 0..1 in the upright, un-mirrored source image. Null when no
  /// face was found this frame. In multi-face mode this is the first face.
  final List<Offset>? landmarks;

  /// All tracked faces, in the pipeline's stable track order. One entry in
  /// single-face mode; up to `maxFaces` when the source was started with it.
  final List<List<Offset>> faces;

  /// Pixel size of that upright image.
  final Size sourceSize;

  /// The raw camera buffer, for filters that sample the video (the tiger
  /// does). On Android this is NV21's Y plane — already BT.601 luma, one byte
  /// per pixel, which is exactly and only what the tiger's shader wants. On
  /// iOS it is the interleaved BGRA buffer, flagged by
  /// [lumaIsInterleaved8888].
  ///
  /// Un-rotated: [rotationDegrees] says what it takes to stand it upright.
  final Uint8List? lumaPlane;
  final int lumaWidth, lumaHeight, lumaRowStride, rotationDegrees;
  final bool lumaIsInterleaved8888;
}

class CameraLandmarkSource {
  CameraLandmarkSource({this.maxFaces = 1});

  /// How many faces to track. Above 1 the pipeline switches to its multi-face
  /// flow, which needs a processor built by `createForMultiFace` — so this has
  /// to be decided before [start].
  final int maxFaces;

  bool get isMultiFace => maxFaces > 1;

  /// Set false to skip attaching the camera buffer to each frame. Filters that
  /// never sample the video pay nothing for it either way — the buffer is
  /// passed by reference, not copied — but this makes the intent explicit.
  bool provideVideo = true;

  CameraController? _cam;
  FaceDetectorProcessor? _detector;
  FaceMeshProcessor? _mesh;
  FaceMeshInferencePipeline? _inference;

  bool _busy = false;
  int _rotation = 0;

  CameraController? get controller => _cam;

  Future<void> start(void Function(LandmarkFrame frame) onFrame) async {
    _detector = await FaceDetectorProcessor.create();
    // The multi-face flow tracks one ROI per face in Dart, and needs a
    // processor built for it — the single-face flow's native ROI tracking
    // would fight it.
    _mesh = isMultiFace
        ? await FaceMeshProcessor.createForMultiFace(enableAttentionMesh: true)
        : await FaceMeshProcessor.create(enableAttentionMesh: true);
    _inference = FaceMeshInferencePipeline(
      detector: _detector!,
      mesh: _mesh!,
      landmarkSmoothing: const LandmarkSmoothingOptions(),
    );

    final cams = await availableCameras();
    final front = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cams.first,
    );
    _rotation = Platform.isAndroid ? front.sensorOrientation : 0;

    final cam = CameraController(
      front,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    await cam.initialize();
    await cam.startImageStream((image) => _onImage(image, onFrame));
    _cam = cam;
  }

  void _onImage(CameraImage image, void Function(LandmarkFrame) onFrame) {
    if (_busy) return;
    _busy = true;
    try {
      final w = image.width, h = image.height;
      final plane = image.planes.first;
      List<Offset>? lm;

      final faces = <List<Offset>>[];

      if (Platform.isAndroid) {
        final nv = FaceMeshNv21Image.tryFromSinglePlane(
          bytes: plane.bytes,
          width: w,
          height: h,
          bytesPerRow: plane.bytesPerRow,
        );
        if (nv != null) {
          if (isMultiFace) {
            final multi = _inference!.processNv21MultiFace(
              nv,
              rotationDegrees: _rotation,
              maxMeshFaces: maxFaces,
            );
            for (final mesh in multi.meshResults) {
              faces.add(mesh.landmarks
                  .map((p) => Offset(p.x, p.y))
                  .toList(growable: false));
            }
            if (faces.isNotEmpty) lm = faces.first;
          } else {
            final mesh = _inference!
                .processNv21(nv, rotationDegrees: _rotation)
                .meshResult;
            if (mesh != null) {
              lm = mesh.landmarks
                  .map((p) => Offset(p.x, p.y))
                  .toList(growable: false);
              faces.add(lm);
            }
          }
        }
      } else {
        final image = FaceMeshImage(
          pixels: plane.bytes,
          width: w,
          height: h,
          pixelFormat: FaceMeshPixelFormat.bgra,
          bytesPerRow: plane.bytesPerRow,
        );

        if (isMultiFace) {
          final multi = _inference!
              .processMultiFace(image, rotationDegrees: 0, maxMeshFaces: maxFaces);
          for (final mesh in multi.meshResults) {
            faces.add(mesh.landmarks
                .map((p) => Offset(p.x, p.y))
                .toList(growable: false));
          }
          if (faces.isNotEmpty) lm = faces.first;
        } else {
          final mesh =
              _inference!.process(image, rotationDegrees: 0).meshResult;
          if (mesh != null) {
            lm = mesh.landmarks
                .map((p) => Offset(p.x, p.y))
                .toList(growable: false);
            faces.add(lm);
          }
        }
      }

      // Rotating the frame upright swaps width and height.
      final swap = _rotation == 90 || _rotation == 270;
      final src = swap
          ? Size(h.toDouble(), w.toDouble())
          : Size(w.toDouble(), h.toDouble());

      onFrame(LandmarkFrame(
        lm,
        src,
        faces: faces,
        lumaPlane: provideVideo ? plane.bytes : null,
        lumaWidth: w,
        lumaHeight: h,
        lumaRowStride: plane.bytesPerRow,
        rotationDegrees: _rotation,
        lumaIsInterleaved8888: !Platform.isAndroid,
      ));
    } catch (e) {
      debugPrint('CameraLandmarkSource frame failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    await _cam?.stopImageStream();
    await _cam?.dispose();
    _detector?.close();
    _mesh?.close();
  }
}
