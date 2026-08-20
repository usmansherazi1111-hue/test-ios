// Asset key resolution.
//
// Flutter namespaces assets by *who owns them at build time*, and this package
// is loaded both ways:
//
//   * as a dependency of another app (beauty-filters/app) — its assets are
//     registered under `packages/jeeliz_dart/assets/…`;
//   * as the app itself (`flutter run` here, driving lib/main.dart) — the root
//     package's assets get bare keys, `assets/…`, with no `packages/` prefix.
//
// Hard-coding either one breaks the other, so probe: try the prefixes in order
// and remember the one that works. The probe returns the bytes it read, so the
// winning attempt is not wasted — resolution costs nothing beyond the first
// asset load.
//
// Probing beats reading AssetManifest because it is authoritative in every
// environment, including `flutter test`, where the manifest may be absent or
// disagree with what the test bundle actually serves.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show ByteData, rootBundle;

const List<String> _kRoots = <String>[
  'packages/jeeliz_dart/assets/',
  'assets/',
];

String? _resolvedRoot;

/// The prefix that worked, once known. Null until the first successful load.
String? get resolvedJeelizAssetRoot => _resolvedRoot;

/// Forget the cached prefix. Only useful in tests.
void resetJeelizAssetRoot() => _resolvedRoot = null;

/// Loads [relative] (e.g. `glassesVTO/envMap.jpg`) from whichever root works.
Future<ByteData> loadJeelizAssetBytes(String relative) async {
  // Cached root first, then the others. Falling through rather than trusting
  // the cache keeps one genuinely-missing file from being misreported as a
  // resolution failure, and vice versa.
  final cached = _resolvedRoot;
  final roots = cached == null
      ? _kRoots
      : <String>[cached, ..._kRoots.where((r) => r != cached)];

  final errors = <String>[];
  for (final root in roots) {
    try {
      final data = await rootBundle.load('$root$relative');
      _resolvedRoot = root;
      return data;
    } catch (e) {
      errors.add('  $root$relative -> $e');
    }
  }
  throw Exception('jeeliz_dart could not find asset "$relative". Tried:\n'
      '${errors.join('\n')}\n'
      'Check that assets/glassesVTO/ is declared in the pubspec of whichever '
      'package owns it.');
}

Future<String> loadJeelizAssetString(String relative) async {
  final data = await loadJeelizAssetBytes(relative);
  return utf8.decode(data.buffer.asUint8List(
      data.offsetInBytes, data.lengthInBytes));
}

/// Convenience for callers that want a plain byte view.
Future<Uint8List> loadJeelizAssetUint8List(String relative) async {
  final data = await loadJeelizAssetBytes(relative);
  return data.buffer
      .asUint8List(data.offsetInBytes, data.lengthInBytes);
}
