{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  git,
  writableTmpDirAsHomeHook,
}:
let
  version = "0.9.0";

  libchdr = fetchFromGitHub {
    owner = "rtissera";
    repo = "libchdr";
    tag = "v0.3.0";
    hash = "sha256-jBk3Kd4q3HO3i2SxS0mBpQ80Vfm8vj1PQMXouK6Y/+k=";
  };

  sdl = fetchFromGitHub {
    owner = "libsdl-org";
    repo = "SDL";
    tag = "release-3.4.12";
    hash = "sha256-b6l3HgdhqIe9LazJmLivbCJgbKPAS8S54fuB9xvgalI=";
  };

  zlib = fetchFromGitHub {
    owner = "madler";
    repo = "zlib";
    tag = "v1.3.1";
    hash = "sha256-TkPLWSN5QcPlL9D0kc/yhH0/puE9bFND24aj5NVDKYs=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "gt3-revisited";
  inherit version;

  src = fetchFromGitHub {
    owner = "matt-pulsipher";
    repo = "GT3-revisited";
    tag = "v${finalAttrs.version}";
    hash = "sha256-cweewYAHxMvc/mEhiOv4QhMj6rioeN2FZdCyIN6tcM0=";
  };

  # CMake's Xcode generator and the Apple SDK are required for this target.
  __darwinAllowLocalNetworking = stdenv.hostPlatform.isDarwin;
  __noChroot = stdenv.hostPlatform.isDarwin;

  nativeBuildInputs = [
    cmake
    git
    writableTmpDirAsHomeHook
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    if [[ "$(uname -s)" != Darwin ]]; then
      echo "gt3-revisited requires Darwin + Xcode" >&2
      exit 1
    fi

    export HOME="$NIX_BUILD_TOP/.home"
    export CFFIXED_USER_HOME="$HOME"
    export XDG_CACHE_HOME="$HOME/Library/Caches"
    mkdir -p "$HOME/Library/Developer/Xcode/DerivedData" "$XDG_CACHE_HOME"

    if [ -z "''${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    xcodebuild="$DEVELOPER_DIR/usr/bin/xcodebuild"
    [ -x "$xcodebuild" ] || {
      echo "xcodebuild not found under $DEVELOPER_DIR" >&2
      exit 1
    }

    export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
    export CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    export CXX="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
    export LD="$CC"
    export LDPLUSPLUS="$CXX"
    unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS NIX_DYNAMIC_LINKER

    cmake -S . -B build-ios -G Xcode \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT=iphoneos \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
      -DCMAKE_C_COMPILER="$CC" \
      -DCMAKE_CXX_COMPILER="$CXX" \
      -DGT3R_BUILD_TOOLS=OFF \
      -DGT3R_BUILD_TESTS=OFF \
      -DGT3R_FETCH_SDL=ON \
      -DFETCHCONTENT_SOURCE_DIR_LIBCHDR=${libchdr} \
      -DFETCHCONTENT_SOURCE_DIR_SDL3=${sdl} \
      -DFETCHCONTENT_SOURCE_DIR_ZLIB=${zlib} \
      -DGT3R_IOS_TEAM= \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
      -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY= \
      -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=

    cmake --build build-ios --config Release --target gt3r -- -quiet \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      DEVELOPMENT_TEAM="" \
      ENABLE_USER_SCRIPT_SANDBOXING=NO

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d "$out"
    mv build-ios/Release-iphoneos/gt3r.app "$out/gt3r.app"
    runHook postInstall
  '';

  meta = {
    description = "Open reimplementation of the Gran Turismo 3 engine for iOS";
    homepage = "https://github.com/matt-pulsipher/GT3-revisited";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
})
