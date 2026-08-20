/// Pure Dart/Flutter port of the Jeeliz FaceFilter demos.
///
/// No JavaScript, no WebView, no three.js: the scene graph, the pose maths and
/// the renderer are all Dart, and the 3D assets are the demo's own.
///
/// Ported so far: **glassesVTO**.
///
/// ```dart
/// final controller = JeelizGlassesController()..load();
/// // ...then, per tracked camera frame:
/// controller.feedLandmarks(landmarks, sourceSize);
/// // ...and in build():
/// Stack(children: [CameraPreview(cam), JeelizGlassesOverlay(controller: controller)]);
/// ```
library;

export 'src/core/assets.dart'
    show
        loadJeelizAssetBytes,
        loadJeelizAssetString,
        loadJeelizAssetUint8List,
        resolvedJeelizAssetRoot;
export 'src/core/gltf.dart'
    show
        GltfDocument,
        GltfMaterial,
        GltfNode,
        GltfPrimitive,
        GltfPrimitiveInstance,
        GltfTextureRef,
        parseGltf,
        quaternionToMat4;
export 'src/core/geometry.dart'
    show
        BufferGeometry,
        GeometryGroup,
        SortAxis,
        decodeBufferGeometry,
        loadBufferGeometry,
        parseBufferGeometryJson,
        sortGeometryFaces;
export 'src/core/standard_materials.dart'
    show
        BasicColorMaterial,
        LambertMaterial,
        IncidentLight,
        PhongMaterial,
        SpriteMaterial,
        StandardMaterial,
        forEachDirectLight,
        lambertIrradiance,
        specularMipLevel,
        srgbToLinear;
export 'src/core/video_texture.dart'
    show VideoLumaSampler, VideoLumaTexture, VideoRotation, videoRotationFromDegrees;
export 'src/core/material.dart'
    show
        BlendMode,
        Fragment,
        FramesMaterial,
        LensesMaterial,
        Material,
        MaterialSide,
        OccluderMaterial;
export 'src/core/scene.dart'
    show
        AmbientLight,
        DirectionalLight,
        LightingContext,
        Mesh,
        PointLight,
        Object3D,
        PerspectiveCamera,
        Scene,
        Sprite,
        pointLightAttenuation;
export 'src/core/texture.dart'
    show CubeTexture, EquirectTexture, Texture2D, TextureWrap;
export 'src/core/flex_material.dart'
    show FlexMaterial, decomposeWorldMatrix;
export 'src/core/legacy_geometry.dart'
    show LegacyGeometry, decodeLegacyGeometry, parseLegacyGeometryJson;
export 'src/css3d/css3d_transform.dart'
    show Css3dPlacer, Css3dPose, Css3dSettings;
export 'src/faceswap/art_painting.dart'
    show
        ArtPainting,
        ArtPaintingSettings,
        FaceBox,
        buildArtPainting,
        clampToBorder,
        cutFaceHole,
        hueSignature;
export 'src/faceswap/art_painting_controller.dart'
    show
        ArtPaintingController,
        ArtPaintingView,
        kArtPaintings,
        kJocondeFace;
export 'src/faceswap/face_swap.dart'
    show FaceSwapCompositor, hsvToRgb, rgbToHsv;
export 'src/filters/butterflies.dart' show ButterfliesFilter;
export 'src/filters/casa_de_papel.dart' show CasaDePapelFilter;
export 'src/filters/cel_face.dart' show CelFaceFilter;
export 'src/filters/cel_material.dart'
    show
        CelFaceMaterial,
        hsvDegreesToRgb,
        nearestHueLevel,
        nearestSaturationLevel,
        nearestValueLevel,
        rgbToHsvDegrees;
export 'src/filters/cloud.dart' show CloudFilter;
export 'src/filters/halloween_spider.dart'
    show HalloweenSpiderFilter, SpiderFaceMaterial;
export 'src/filters/luffys_hat.dart'
    show LuffysHatFilter, LuffysHatPart;
export 'src/filters/matrix.dart'
    show MatrixFilter, MatrixMaskMaterial;
export 'src/filters/matrix_rain.dart' show MatrixRain;
export 'src/filters/multi_liberty.dart' show MultiLibertyFilter;
export 'src/filters/dog_face.dart' show DogFaceFilter;
export 'src/filters/filter.dart' show ForegroundLayout, JeelizFilter;
export 'src/filters/gltf_helmet.dart' show GltfHelmetFilter;
export 'src/filters/fireworks.dart'
    show FireworksFilter, fireworksSprite;
export 'src/filters/glasses_vto.dart'
    show
        GlassesAssets,
        GlassesFilter,
        GlassesFrameModel,
        buildGlassesScene,
        createGlasses;
export 'src/filters/rupy_helmet.dart'
    show HelmetFaceMaterial, RupyHelmetFilter;
export 'src/filters/tiger.dart' show TigerFilter, planeGeometry;
export 'src/filters/tiger_material.dart' show TigerMaskMaterial;
export 'src/math/vec_mat.dart' show Euler, EulerOrder, Mat4, Vec2, Vec3;
export 'src/render/renderer.dart'
    show Framebuffer, RenderStats, SoftwareRenderer;
export 'src/tracking/detect_state.dart' show DetectState;
export 'src/tracking/face_filter_helper.dart'
    show DetectCallback, JeelizFaceFilterHelper, JeelizHelperSettings;
export 'src/tracking/landmark_adapter.dart'
    show
        JeelizCubeCalibration,
        LandmarkDetectStateAdapter,
        LandmarkPose,
        kCanonicalFace,
        solveLandmarkPose;
export 'src/widget/css3d_overlay.dart'
    show ComedyGlassesImage, JeelizCss3dController, JeelizCss3dOverlay;
export 'src/widget/filter_overlay.dart'
    show JeelizFilterController, JeelizFilterOverlay;
export 'src/widget/glasses_overlay.dart'
    show JeelizGlassesController, JeelizGlassesOverlay;
