// Nix build: use prebuilt libnative_core_ffi.so instead of rustup/cargo.
// assetName must match ffigen.yaml / lib/src/bindings.g.dart @Native assetId.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    // @NATIVE_CORE_FFI_PREBUILT@ is substituted by the Nix package.
    const prebuiltRoot = '@NATIVE_CORE_FFI_PREBUILT@';
    if (prebuiltRoot.startsWith('@')) {
      throw StateError('NATIVE_CORE_FFI_PREBUILT was not substituted by Nix');
    }

    final abi = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.android, Architecture.arm) => 'armeabi-v7a',
      (OS.android, Architecture.arm64) => 'arm64-v8a',
      (OS.android, Architecture.x64) => 'x86_64',
      _ => throw UnsupportedError(
        'unsupported native_core target: ${code.targetOS} ${code.targetArchitecture}',
      ),
    };

    final so = File('$prebuiltRoot/$abi/libnative_core_ffi.so');
    if (!so.existsSync()) {
      throw StateError('missing prebuilt native_core_ffi for $abi at ${so.path}');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/bindings.g.dart',
        linkMode: DynamicLoadingBundled(),
        file: so.uri,
      ),
    );
  });
}
