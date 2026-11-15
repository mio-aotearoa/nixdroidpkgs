// Minimal Dart FFI bindings for Immich's package:native_core.
// Mirrors the Dart-facing symbols from upstream native_core (version/free_string);
// Android JNI entry points are in the prebuilt .so and do not need Dart stubs.
// assetId must match hook/build.dart and upstream ffigen.yaml.
// Source: https://github.com/immich-app/immich (mobile native_core / AGPL-3.0)
// ignore_for_file: type=lint

import 'dart:ffi';

@Native<Pointer<Char> Function()>(
  symbol: 'native_core_version',
  assetId: 'package:native_core/src/bindings.g.dart',
)
external Pointer<Char> native_core_version();

@Native<Void Function(Pointer<Char>)>(
  symbol: 'native_core_free_string',
  assetId: 'package:native_core/src/bindings.g.dart',
)
external void native_core_free_string(Pointer<Char> ptr);
