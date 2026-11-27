{
  lib,
  stdenv,
  buildDartApplication,
  fetchFromGitHub,
  fetchzip,
  flutter347,
  cocoapods,
  cmake,
  findutils,
  git,
  python3,
  runCommand,
  writeShellScriptBin,
  writableTmpDirAsHomeHook,
}:
let
  common = import ../../apks/meshcore-open/common.nix { inherit fetchFromGitHub; };
  mkFlutterSdkSourceBuilder = import ../../apks/_shared/mk-flutter-sdk-source-builder.nix;
  onnxruntime = fetchzip {
    # Pinned by the vendored flutter_onnxruntime package's Package.swift.
    url = "https://github.com/masicai/onnxruntime-swift-package-manager/releases/download/1.28.0/onnxruntime-libs-1.28.0.zip";
    hash = "sha256-VPbMfxdie+4/RYx3oTvGwHjVhEdrIKsLKVthgtXeNv0=";
    stripRoot = false;
  };
  codesignShim = writeShellScriptBin "codesign" ''
    exit 0
  '';
in
buildDartApplication.override { dart = flutter347; } (finalAttrs: {
  pname = "meshcore-open-ios";
  inherit (common) version src;
  patches = common.patches ++ [ ./add-local-onnxruntime-pod.patch ];

  # Flutter's iOS build invokes Xcode and CocoaPods on the host SDK.
  __darwinAllowLocalNetworking = stdenv.hostPlatform.isDarwin;
  __noChroot = stdenv.hostPlatform.isDarwin;

  pubspecLock = lib.importJSON ../../apks/meshcore-open/pubspec.lock.json;

  # Match the Android package: MeshCore only uses sqlite3's SQLite backend,
  # so avoid the version-specific SQLCipher download hook on iOS too.
  customSourceBuilders.sqlite3 =
    { version, src, ... }:
    stdenv.mkDerivation {
      pname = "sqlite3";
      inherit version src;
      inherit (src) passthru;
      postPatch = ''
        substituteInPlace lib/src/hook/compile/description.dart \
          --replace-fail "return fromGitHub(LibraryType.sqlite3);" "return LookupSystem('sqlite3');"
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        shopt -s dotglob
        mv ./* "$out/"
        runHook postInstall
      '';
    };

  sdkSourceBuilders = {
    flutter = mkFlutterSdkSourceBuilder {
      inherit runCommand;
      flutter = flutter347;
    };
  };

  nativeBuildInputs = [
    codesignShim
    cocoapods
    cmake
    git
    python3
    writableTmpDirAsHomeHook
  ];

  dontDartBuild = true;
  dontDartInstall = true;
  dontConfigure = true;

  sdkSetupScript = ''
    flutter config --no-analytics >/dev/null 2>&1 || true
  '';

  postPatch = ''
    # Keep the shared source revision compatible with the pinned Flutter SDK.
    substituteInPlace pubspec.yaml \
      --replace-fail 'flutter: 3.47.9' 'flutter: ${flutter347.version}'
    substituteInPlace ios/Runner.xcodeproj/project.pbxproj \
      --replace-fail '"iPhone Developer";' '"";'

    # The upstream podspec downloads the same ORT binary from
    # download.onnxruntime.ai. Use the pinned GitHub archive instead so the
    # iOS build has no network-dependent CocoaPods binary fetch.
    mkdir -p third_party/onnxruntime-objc
    cp -R third_party/flutter_onnxruntime/ios/flutter_onnxruntime/onnxruntime-swift-package-manager/objectivec \
      third_party/onnxruntime-objc/
    cp -R ${onnxruntime}/onnxruntime.xcframework/ios-arm64/Headers/onnxruntime/. third_party/onnxruntime-objc/
    mkdir -p third_party/flutter_onnxruntime/ios/flutter_onnxruntime/Sources/flutter_onnxruntime_objc/vendor/onnxruntime
    cp -R ${onnxruntime}/onnxruntime.xcframework/ios-arm64/Headers/onnxruntime/. \
      third_party/flutter_onnxruntime/ios/flutter_onnxruntime/Sources/flutter_onnxruntime_objc/vendor/onnxruntime/
    cp ${onnxruntime}/onnxruntime.xcframework/ios-arm64/libonnxruntime-ios.a third_party/onnxruntime-objc/
    cp ${./onnxruntime-objc.podspec} third_party/onnxruntime-objc/onnxruntime-objc.podspec
  '';

  buildPhase = ''
    runHook preBuild

    if [[ "$(uname -s)" != Darwin ]]; then
      echo "meshcore-open-ios requires Darwin + Xcode" >&2
      exit 1
    fi

    export HOME="$NIX_BUILD_TOP/.home"
    export CFFIXED_USER_HOME="$HOME"
    export TMPDIR="$NIX_BUILD_TOP/tmp"
    export XDG_CACHE_HOME="$HOME/Library/Caches"
    export COCOAPODS_DISABLE_STATS=true
    export SSL_CERT_FILE=/private/etc/ssl/cert.pem
    export SSL_CERT_DIR=/private/etc/ssl/certs
    export NIX_SSL_CERT_FILE="$SSL_CERT_FILE"
    export CODE_SIGN_IDENTITY=""
    export DEVELOPMENT_TEAM=""
    mkdir -p "$TMPDIR" "$HOME/Library/Developer/Xcode/DerivedData" "$XDG_CACHE_HOME"

    if [ -z "''${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    xcodebuild="$DEVELOPER_DIR/usr/bin/xcodebuild"
    [ -x "$xcodebuild" ] || {
      echo "xcodebuild not found under $DEVELOPER_DIR" >&2
      exit 1
    }
    export SDKROOT="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
    [ -d "$SDKROOT" ] || {
      echo "iPhoneOS SDK not found at $SDKROOT" >&2
      exit 1
    }

    export PATH="${codesignShim}/bin:${findutils}/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    export CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    export CXX="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
    unset LD AR RANLIB NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS NIX_DYNAMIC_LINKER

    flutter config --no-enable-swift-package-manager >/dev/null 2>&1 || true
    flutter pub get --enforce-lockfile
    patch -p1 < ${./disable-swift-package-resolution.patch}
    flutter build ios --release --no-pub --no-codesign \
      --build-name="${lib.head (lib.splitString "+" finalAttrs.version)}" \
      --build-number="${lib.last (lib.splitString "+" finalAttrs.version)}" \
      --dart-define=APP_VERSION="${lib.head (lib.splitString "+" finalAttrs.version)}-tak" \
      --dart-define=APP_BUILD="${lib.last (lib.splitString "+" finalAttrs.version)}"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d "$out"
    mv build/ios/iphoneos/Runner.app "$out/meshcore-open.app"
    runHook postInstall
  '';

  meta = with lib; {
    sourceProvenance = with sourceTypes; [ fromSource ];
    description = "MeshCore Open TAK Flutter client for iOS";
    homepage = "https://github.com/jade-on-mesh/meshcore-open-tak";
    license = licenses.mit;
    platforms = platforms.darwin;
  };
})
