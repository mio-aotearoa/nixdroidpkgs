{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs_24,
  cacert,
  unzip,
  writableTmpDirAsHomeHook,
  nix-update,
  writeShellScriptBin,
  git,
}:
let
  version = "5.15.1";

  # Builds the unsigned Capacitor iOS app.
  # Needs host Xcode; __noChroot requires sandbox = relaxed (or false):
  #   nix build .#ios_electerm

  src = fetchFromGitHub {
    owner = "electerm";
    repo = "electerm-ios";
    rev = "46bc4a0dede8a0ac0ce1ac8f76d46b7ae1fc19d5";
    hash = "sha256-xcbdpd7fjK/nizDAsRHiCotnu+qdtZEvTQ5wwSnPF38=";
  };

  electermWebSrc = fetchFromGitHub {
    owner = "electerm";
    repo = "electerm-web";
    rev = "9178e08ed83411d5bc6a4b367fe9ca35b6cb186c";
    hash = "sha256-rjjld61SA+UsSrnZLZ1jjxULbDIShFFV1BHT03hKVhQ=";
  };

  nodeMobileIos = fetchurl {
    url = "https://github.com/capawesome-team/nodejs-mobile/releases/download/v18.20.4-capawesome.1/nodejs-mobile-v18.20.4-capawesome.1-ios.zip";
    hash = "sha256-jFyjoNHjjefxgqVkJZPoJZO4IO/TdaFLPsr8S8/uYg4=";
  };

  installNodeModules =
    name: source: hash:
    stdenv.mkDerivation {
      inherit name;
      src = source;
      nativeBuildInputs = [
        nodejs_24
        cacert
      ];
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hash;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR"
        npm ci --ignore-scripts --no-audit --no-fund
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        mv node_modules "$out/"
        runHook postInstall
      '';
    };

  nodeModules =
    installNodeModules "electerm-ios-${version}-node-modules" src
      "sha256-MvkXfH0LQh6Txu7u8iiOlZyj2gi3VU1OSn/2lFib24w=";
  iosNodeModules =
    installNodeModules "electerm-ios-${version}-ios-node-modules" "${src}/build/ios"
      "sha256-1L48/4eAMkyGNfbwVYx6wdOe/xKKHq8OwJjwEveKBf8=";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "electerm-ios";
  inherit version src;

  __darwinAllowLocalNetworking = stdenv.hostPlatform.isDarwin;
  __noChroot = stdenv.hostPlatform.isDarwin;

  nativeBuildInputs = [
    nodejs_24
    unzip
    writableTmpDirAsHomeHook
  ];

  postPatch = ''
    cp -a ${nodeModules}/node_modules .
    cp -a ${iosNodeModules}/node_modules build/ios/node_modules
    chmod -R u+w node_modules build/ios/node_modules
    mkdir -p build/ios/node_modules/@capawesome/capacitor-nodejs/ios/libnode
    unzip -q ${nodeMobileIos} -d build/ios/node_modules/@capawesome/capacitor-nodejs/ios/libnode

    # electerm-ios reuses electerm-web's source tree during npm install. Keep
    # that network-dependent step reproducible inside the Nix build sandbox.
    rm -rf src
    cp -a ${electermWebSrc}/src src
    chmod -R u+w src

    overlay=build/replace/src
    if [ -d "$overlay" ]; then
      (cd "$overlay" && find . -type f) | while IFS= read -r rel; do
        install -Dm644 "$overlay/$rel" "src/$rel"
      done
    fi
    rm -rf src/client/electerm-react
    mkdir -p src/client/electerm-react
    cp -a node_modules/@electerm/electerm-react/client/. src/client/electerm-react/
    if [ -d "$overlay/client/electerm-react" ]; then
      (cd "$overlay/client/electerm-react" && find . -type f) | while IFS= read -r rel; do
        install -Dm644 "$overlay/client/electerm-react/$rel" "src/client/electerm-react/$rel"
      done
    fi
    node -p "require('./node_modules/@electerm/electerm-react/package.json').version" \
      > src/client/electerm-react/version
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$NIX_BUILD_TOP/.home"
    export CFFIXED_USER_HOME="$HOME"
    mkdir -p "$HOME/Library/Developer/Xcode/DerivedData"
    export XDG_CACHE_HOME="$HOME/Library/Caches"
    export SWIFT_PACKAGE_MANAGER_CACHE_PATH="$HOME/Library/Caches/org.swift.swiftpm"
    export CLANG_MODULE_CACHE_PATH="$HOME/Library/Developer/Xcode/ModuleCache.noindex"
    export CORE_SIMULATOR_DEVICE_SET_PATH="$HOME/Library/Developer/CoreSimulator/Devices"
    mkdir -p "$SWIFT_PACKAGE_MANAGER_CACHE_PATH" "$CLANG_MODULE_CACHE_PATH" \
      "$CORE_SIMULATOR_DEVICE_SET_PATH"
    export SWIFTPM_DISABLE_SANDBOX=1
    export SWIFTC_DISABLE_SANDBOX=1
    export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
    export CC=/usr/bin/clang
    export CXX=/usr/bin/clang++
    export LD=/usr/bin/clang
    export LDPLUSPLUS=/usr/bin/clang++
    unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS NIX_DYNAMIC_LINKER
    if [ -z "''${DEVELOPER_DIR:-}" ] || [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    xcodebuild="$DEVELOPER_DIR/usr/bin/xcodebuild"
    [ -x "$xcodebuild" ] || {
      echo "xcodebuild not found under $DEVELOPER_DIR" >&2
      exit 1
    }

    if [[ "$(uname -s)" != Darwin ]]; then
      echo "electerm-ios requires Darwin + Xcode" >&2
      exit 1
    fi

    node build/ios/build.mjs
    cd build/ios
    node - <<'NODE'
    const fs = require('fs');
    const p = 'node_modules/@capacitor/cli/dist/common.js';
    let c = fs.readFileSync(p, 'utf8');
    c = c.replace(
      /async function checkAppId\(config, id\) \{[\s\S]*?\nexports\.checkAppId = checkAppId;/,
      'async function checkAppId(config, id) { return null; }\nexports.checkAppId = checkAppId;'
    );
    fs.writeFileSync(p, c);
    NODE
    node node_modules/@capacitor/cli/bin/capacitor add ios
    node node_modules/@capacitor/cli/bin/capacitor sync ios
    node build.mjs --overlay-only
    cd ios/App
    swift_package="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    [ -x "$swift_package" ] || {
      echo "swift not found under $DEVELOPER_DIR" >&2
      exit 1
    }
    package_manifest="$(find . -path '*/node_modules' -prune -o -name Package.swift -print -quit)"
    [ -n "$package_manifest" ] && [ -f "$package_manifest" ] || {
      echo "Capacitor did not generate a Package.swift" >&2
      exit 1
    }
    package_dir="$(dirname "$package_manifest")"
    (cd "$package_dir" && "$swift_package" package resolve --disable-sandbox)
    resolved_file="$package_dir/Package.resolved"
    [ -f "$resolved_file" ] || {
      echo "SwiftPM did not generate Package.resolved" >&2
      exit 1
    }
    xcode_resolved_dir="App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
    mkdir -p "$xcode_resolved_dir"
    cp "$resolved_file" "$xcode_resolved_dir/Package.resolved"
    mkdir -p "$HOME/Library/Developer/Xcode/DerivedData/SourcePackages"
    "$xcodebuild" \
      -project App.xcodeproj -scheme App \
      -configuration Release \
      -sdk iphoneos \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$NIX_BUILD_TOP/DerivedData" \
      -IDEPackageSupportDisableManifestSandbox=1 \
      -IDEPackageSupportDisablePluginExecutionSandbox=1 \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      DEVELOPMENT_TEAM="" \
      ENABLE_USER_SCRIPT_SANDBOXING=NO \
      OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
      build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -d "$out"
    cp -a "$NIX_BUILD_TOP/DerivedData/Build/Products/Release-iphoneos/App.app" "$out/electerm.app"
    runHook postInstall
  '';

  passthru = {
    inherit
      electermWebSrc
      nodeModules
      iosNodeModules
      nodeMobileIos
      ;
    updateScript = writeShellScriptBin "update-electerm-ios" ''
      set -euo pipefail
      package_file="app/ios/electerm/package.nix"
      package_attr=".#ios_electerm"
      fake_hash="${lib.fakeHash}"
      . "${../../apks/_shared/update-script-helpers.sh}"
      ${lib.getExe nix-update} --flake --src-only ios_electerm
      web_rev="$(${lib.getExe git} ls-remote https://github.com/electerm/electerm-web.git refs/heads/main | cut -f1)"
      [[ -n "$web_rev" ]] || { echo "could not resolve electerm-web main" >&2; exit 1; }
      old_rev="$(sed -n 's/^[[:space:]]*rev = "\([0-9a-f]*\)";$/\1/p' "$package_file" | head -n 2 | tail -n 1)"
      replace_literal "rev = \"$old_rev\";" "rev = \"$web_rev\";"
      refresh_update_deps nodeModules iosNodeModules electermWebSrc
    '';
  };

  meta = {
    description = "electerm SSH, SFTP, Telnet, RDP, VNC, Spice and FTP client for iOS";
    homepage = "https://github.com/electerm/electerm-ios";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
})
