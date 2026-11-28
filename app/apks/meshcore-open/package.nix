{
  mk-apk-package,
  lib,
  stdenv,
  buildDartApplication,
  runCommand,
  fetchFromGitHub,
  fetchurl,
  libaom,
  cmake,
  ninja,
  perl,
  flutter347,
  jdk17_headless,
  python3,
  gradle_8_14_5,
  writableTmpDirAsHomeHook,
  androidSdkBuilder,
  writeShellScriptBin,
  jq,
  curl,
}:
let
  flutterApkHelpers = ../_shared/flutter-apk-helpers.sh;
  mkFlutterSdkSourceBuilder = import ../_shared/mk-flutter-sdk-source-builder.nix;
  meshcoreCommon = import ./common.nix { inherit fetchFromGitHub; };

  appPackage =
    let
      # Upstream llamadart downloads these at build time; vendor the release
      # tarballs instead so the sandboxed build stays offline.
      llamadartNativeAndroidArm64 = fetchurl {
        url = "https://github.com/leehack/llamadart-native/releases/download/v0.4.1/llamadart-native-android-arm64-v0.4.1.tar.gz";
        hash = "sha256-/KUvYl4Za09dU7XcvpZGtrdkHu29f2GrEnLd1ewKnuQ=";
      };

      llamadartNativeAndroidX64 = fetchurl {
        url = "https://github.com/leehack/llamadart-native/releases/download/v0.4.1/llamadart-native-android-x64-v0.4.1.tar.gz";
        hash = "sha256:115fh0s0vzqsis4n8vf5kbxnqvbqi879s1kbskgl7fnbx9s6n712";
      };

      litertLMNativeAndroidArm64 = fetchurl {
        url = "https://github.com/leehack/litert-lm-native/releases/download/v0.17.0-6/litert-lm-native-runtime-android-arm64-v0.17.0-6.tar.gz";
        hash = "sha256:02abzgdrxnj9mp37z10y3rhxadxbsinyw7xfgh6a8dnwhfp22w40";
      };

      litertLMNativeAndroidX64 = fetchurl {
        url = "https://github.com/leehack/litert-lm-native/releases/download/v0.17.0-6/litert-lm-native-runtime-android-x64-v0.17.0-6.tar.gz";
        hash = "sha256:1hcfwcck22g12cbxd0k45w3sdy9g3zfb4hp21xi1q8y3m6x6k8a5";
      };

      sqliteAndroid = fetchurl {
        url = "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/libsqlite3.arm64.android.so";
        hash = "sha256-5oTvhkb/1IuVuuWL8pxV/9hazrrCpxGP/en9At831ik=";
      };
      ncnnSource = fetchFromGitHub {
        owner = "Tencent";
        repo = "ncnn";
        rev = "b0f97f43f266617ff5e5096d440dbe3f9a4c35b8";
        hash = "sha256-qR50crX+rCkB7134h2URkKeN9M5dcd9HYoK6eJml7ww=";
      };
      aeicSource = fetchFromGitHub {
        owner = "mikecarper";
        repo = "AEIC";
        rev = "b00795ca709354f987e868f6b9e608961ec80831";
        hash = "sha256-g+g4bQvk52xa2bt6dPvVOyUGOqfTO1Cr8ocFv1eA3/E=";
      };

      androidSdk = androidSdkBuilder (s: [
        s.cmdline-tools-latest
        s.platform-tools
        s.platforms-android-35
        s.platforms-android-36
        # AGP may resolve aapt2 from build-tools 35.0.0 even with compileSdk 36.
        s.build-tools-35-0-0
        s.build-tools-36-0-0
        # App uses 29 (upstream); jni/jni_flutter plugins still declare 28.2.
        # Do not set ndk.dir in local.properties — let AGP pick per-module.
        s.ndk-26-3-11579264
        s.ndk-28-2-13676358
        s.ndk-29-0-14206865
        s.cmake-3-31-6
      ]);

      gradle = gradle_8_14_5;
      androidSdkRoot = "${androidSdk}/share/android-sdk";
      aapt2 = "${androidSdkRoot}/build-tools/35.0.0/aapt2";

      nativeCodecs =
        runCommand "meshcore-open-tak-native-codecs"
          {
            nativeBuildInputs = [
              cmake
              ninja
              perl
            ];
          }
          ''
            # Match jade-on-mesh/meshcore-open-tak's native codec builds (MIT):
            # https://github.com/jade-on-mesh/meshcore-open-tak/blob/d9e435284791e0d4ad0fb371dce985c739c3b033/.github/workflows/build.yml
            # https://github.com/jade-on-mesh/meshcore-open-tak/blob/d9e435284791e0d4ad0fb371dce985c739c3b033/tool/build_aeic_hd_android.sh
            # All sources are fetched by Nix so these builds remain offline.
            toolchain="${androidSdkRoot}/ndk/29.0.14206865/build/cmake/android.toolchain.cmake"
            cmake -S ${libaom.src} -B aom-build -G Ninja \
              -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI=arm64-v8a \
              -DANDROID_PLATFORM=android-21 -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_ASM_COMPILER="${androidSdkRoot}/ndk/29.0.14206865/toolchains/llvm/prebuilt/${
                if stdenv.hostPlatform.isDarwin then "darwin-x86_64" else "linux-x86_64"
              }/bin/aarch64-linux-android21-clang" \
              -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DENABLE_DOCS=0 \
              -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TESTDATA=0 \
              -DENABLE_TOOLS=0 -DCONFIG_AV1_HIGHBITDEPTH=0 -DCONFIG_WEBM_IO=0
            cmake --build aom-build --parallel "$NIX_BUILD_CORES" --target aom
            mkdir -p third_party/aom-android/arm64-v8a/{lib,include/aom}
            mv aom-build/libaom.a third_party/aom-android/arm64-v8a/lib/
            cp ${libaom.src}/aom/*.h third_party/aom-android/arm64-v8a/include/aom/
            cp aom-build/config/aom_config.h third_party/aom-android/arm64-v8a/include/aom/

            cmake -S ${ncnnSource} -B ncnn-build -G Ninja \
              -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI=arm64-v8a \
              -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
              -DCMAKE_BUILD_TYPE=Release -DNCNN_VERSION=20261013 \
              -DNCNN_VULKAN=OFF -DNCNN_SHARED_LIB=OFF -DNCNN_BUILD_TOOLS=OFF \
              -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
              -DNCNN_ARM82=OFF -DNCNN_ARM82DOT=OFF -DNCNN_ARM82FP16FML=OFF \
              -DNCNN_ARM84BF16=OFF -DNCNN_ARM84I8MM=OFF \
              -DNCNN_ARM86SVE=OFF -DNCNN_ARM86SVE2=OFF \
              -DCMAKE_INSTALL_PREFIX="$PWD/ncnn-install"
            cmake --build ncnn-build --parallel "$NIX_BUILD_CORES"
            cmake --install ncnn-build
            cmake -S ${aeicSource}/mobile/native -B aeic-build -G Ninja \
              -DCMAKE_TOOLCHAIN_FILE="$toolchain" -DANDROID_ABI=arm64-v8a \
              -DANDROID_PLATFORM=android-21 -DANDROID_STL=c++_static \
              -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
              -Dncnn_DIR="$PWD/ncnn-install/lib/cmake/ncnn"
            cmake --build aeic-build --parallel "$NIX_BUILD_CORES"
            mkdir -p android/app/src/main/jniLibs/arm64-v8a
            mv aeic-build/aeic_decode android/app/src/main/jniLibs/arm64-v8a/libaeic_codec_exec.so
            cp ${sqliteAndroid} android/app/src/main/jniLibs/arm64-v8a/libsqlite3.so

            mkdir -p "$out/third_party" "$out/lib"
            mv third_party/aom-android "$out/third_party/"
            mv android/app/src/main/jniLibs/arm64-v8a/*.so "$out/lib/"
          '';

      pythonWithYaml = python3.withPackages (ps: [ ps.pyyaml ]);
    in
    buildDartApplication.override { dart = flutter347; } (finalAttrs: {
      pname = "meshcore-open";
      inherit (meshcoreCommon) version;

      __darwinAllowLocalNetworking = true;
      __noChroot = stdenv.hostPlatform.isDarwin;

      inherit (meshcoreCommon) src;

      # The TAK fork already removes the node banner.
      inherit (meshcoreCommon) patches;

      pubspecLock = lib.importJSON ./pubspec.lock.json;

      # Follow the Android sqlite3 handling used by apk_immich. Only the
      # SQLite backend is used; avoid nixpkgs' version-specific SQLCipher hook.
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

      # $(nix build .#apk_meshcore-open.mitmCache.updateScript --no-link --print-out-paths)
      mitmCache = gradle.fetchDeps {
        inherit (finalAttrs) pname;
        attrPath = "apk_meshcore-open";
        pkg = finalAttrs.finalPackage.overrideAttrs {
          gradleUpdateScript = ''
            runHook preConfigure
            runHook preBuild
            flutter build apk --release --no-pub --target-platform android-arm64 --build-number=${lib.last (lib.splitString "+" finalAttrs.version)}
          '';
        };
        data = ./meshcore-open_deps.json;
        silent = false;
        useBwrap = false;
      };

      passthru = {
        inherit (finalAttrs) mitmCache;
        inherit nativeCodecs;
        codecSources = { inherit ncnnSource aeicSource sqliteAndroid; };
        updateScript = writeShellScriptBin "update-meshcore-open" ''
          set -euo pipefail
          # version, rev and source hash live in common.nix (shared with app/ios).
          package_file="app/apks/meshcore-open/common.nix"
          package_attr=".#apk_meshcore-open"
          fake_hash="${lib.fakeHash}"

          . "${../_shared/update-script-helpers.sh}"

          auth_header=()
          if [[ -n "''${GITHUB_TOKEN:-}" ]]; then
            auth_header=(-H "Authorization: token $GITHUB_TOKEN")
          fi
          latest_rev="$(${lib.getExe curl} -fsSL "''${auth_header[@]}" "https://api.github.com/repos/jade-on-mesh/meshcore-open-tak/commits/latest-build" | ${lib.getExe jq} -er '.sha')"
          current_rev="$(nix eval --raw "$package_attr.src.rev")"
          if [[ "$latest_rev" == "$current_rev" ]]; then
            echo "meshcore-open is already up to date"
            exit 0
          fi

          pubspec_yaml="$(${lib.getExe curl} -fsSL "https://raw.githubusercontent.com/jade-on-mesh/meshcore-open-tak/$latest_rev/pubspec.yaml")"
          upstream_version="$(echo "$pubspec_yaml" | sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' | head -n 1)"
          if [[ -z "$upstream_version" ]]; then
            echo "Could not read the upstream version" >&2
            exit 1
          fi
          release_build="$(${lib.getExe curl} -fsSL "''${auth_header[@]}" "https://api.github.com/repos/jade-on-mesh/meshcore-open-tak/releases/tags/latest-build" | ${lib.getExe jq} -er '.name | capture("build (?<build>[0-9]+)").build')"
          new_version="$upstream_version+$release_build"
          current_version="$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "$package_file" | head -n 1)"

          lock_json_tmp="$(mktemp app/apks/meshcore-open/pubspec.lock.json.XXXXXX)"
          trap 'rm -f "$lock_json_tmp"' EXIT
          ${lib.getExe curl} -fsSL "https://raw.githubusercontent.com/jade-on-mesh/meshcore-open-tak/$latest_rev/pubspec.lock" \
            | ${pythonWithYaml}/bin/python3 -c 'import json, sys, yaml; json.dump(yaml.safe_load(sys.stdin), sys.stdout, indent=2); print()' \
            > "$lock_json_tmp"

          replace_literal "version = \"$current_version\";" "version = \"$new_version\";"
          replace_literal "rev = \"$current_rev\";" "rev = \"$latest_rev\";"
          refresh_fod_hash src
          mv "$lock_json_tmp" app/apks/meshcore-open/pubspec.lock.json

          refresh_mitm_cache
        '';
      };

      gradleUpdateTask = ":app:assembleRelease -x lint -x lintVitalRelease";

      dontDartBuild = true;
      dontDartInstall = true;

      nativeBuildInputs = [
        gradle
        jdk17_headless
        python3
        writableTmpDirAsHomeHook
      ];

      env = {
        JAVA_HOME = jdk17_headless.passthru.home;
        ANDROID_HOME = androidSdkRoot;
        ANDROID_SDK_ROOT = androidSdkRoot;
        ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = aapt2;
      };

      sdkSetupScript = ''
        flutter config --no-analytics >/dev/null 2>&1 || true
      '';

      gradleFlags = [
        "-xlintVitalRelease"
        "--project-dir"
        "android"
        "-Dorg.gradle.java.installations.auto-download=false"
        "-Dorg.gradle.java.installations.paths=${jdk17_headless.passthru.home}"
        "-Dandroid.aapt2FromMavenOverride=${aapt2}"
        "-Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2}"
      ];

      postPatch = ''
        . ${flutterApkHelpers}

        substituteInPlace android/app/build.gradle.kts \
          --replace-fail 'compileSdk = flutter.compileSdkVersion' 'compileSdk = 36'

        # The SDK package follows the same stable Flutter series as upstream.
        substituteInPlace pubspec.yaml \
          --replace-fail 'flutter: 3.47.9' 'flutter: ${flutter347.version}'

        # Preserve the installed app identity and downstream signing workflow.
        substituteInPlace android/app/build.gradle.kts \
          --replace-fail 'applicationId = "com.jadeonmesh.meshcore_open_vox"' 'applicationId = "com.meshcore.meshcore_open"'

        substituteInPlace lib/services/app_update_service.dart \
          --replace-fail "if (PlatformInfo.isAndroid) return 'android';" 'if (PlatformInfo.isAndroid) return null;'

        setup_writable_flutter_sdk ${flutter347}
        # Nixpkgs' Gradle wrapper hardcodes HOME while Flutter itself
        # honors XDG_CACHE_HOME. Keep both in the same local cache.
        substituteInPlace flutter-sdk/packages/flutter_tools/gradle/settings.gradle \
          --replace-fail '$System.env.HOME/.cache/flutter' '$System.env.XDG_CACHE_HOME/flutter'
        setup_pinned_gradlew ${gradle}/bin/gradle
      '';

      preConfigure = ''
        # Keep Flutter's Gradle source links and dependency downloads local to
        # this build, including when the update script runs outside the sandbox.
        export XDG_CACHE_HOME="$PWD/.cache"
        export GRADLE_USER_HOME="$PWD/.gradle"
        export ANDROID_USER_HOME="$HOME/.android"
        mkdir -p "$ANDROID_USER_HOME"
        {
          echo "sdk.dir=${androidSdkRoot}"
          echo "cmake.dir=${androidSdkRoot}/cmake/3.31.6"
          echo "flutter.sdk=$PWD/flutter-sdk"
        } > android/local.properties
      '';

      preBuild = ''
        . ${flutterApkHelpers}

        GRADLE_OPTS="''${GRADLE_OPTS:-}"
        GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.java.installations.auto-download=false"
        GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.java.installations.paths=${jdk17_headless.passthru.home}"
        GRADLE_OPTS="$GRADLE_OPTS -Dandroid.aapt2FromMavenOverride=${aapt2}"
        GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2}"
        append_mitm_gradle_opts
        export FLUTTER_ROOT="$PWD/flutter-sdk"
        export LLAMADART_ALLOW_LEGACY_LOCAL_BUNDLES=1

        cp -R ${nativeCodecs}/third_party/aom-android third_party/
        chmod -R u+w third_party/aom-android
        mkdir -p android/app/src/main/jniLibs/arm64-v8a
        cp ${nativeCodecs}/lib/*.so android/app/src/main/jniLibs/arm64-v8a/

        mkdir -p .dart-patched
        declare -A patched_pkg_dirs

        ${pythonWithYaml}/bin/python3 ${../_shared/generate-flutter-plugins.py}

        # Flutter plugins live in the Nix store; CMake/AGP write under plugin
        # android/ trees (e.g. flserial .cxx/), so clone them to a writable dir.
        while IFS= read -r plugin_dir; do
          [ -n "$plugin_dir" ] || continue
          ensure_writable_dart_package "$plugin_dir" >/dev/null
        done < <(${python3}/bin/python3 - <<'PY'
        import json

        with open(".flutter-plugins-dependencies") as f:
            data = json.load(f)
        for plugin in data.get("plugins", {}).get("android", []):
            path = plugin.get("path", "")
            if path:
                print(path)
        PY
        )

        # Newer Flutter plugins add a kotlin { compilerOptions } block without
        # applying the Kotlin Android plugin. Apply it so the block compiles
        # and Kotlin pigeon sources (e.g. url_launcher Messages.kt) are built.
        while IFS= read -r plugin_gradle; do
          [ -n "$plugin_gradle" ] || continue
          case "$plugin_gradle" in
            *example*) continue ;;
          esac
          if grep -qx 'kotlin {' "$plugin_gradle"; then
            patch -p1 -d "$(dirname "$plugin_gradle")/.." < ${./flutter-android-kotlin-plugin.patch}
          fi
        done < <(find .dart-patched -path '*/android/build.gradle.kts' -print)

        # Vendor llamadart / litert native bundles so hook/build.dart does not
        # hit the network during the sandboxed Flutter build.
        while IFS= read -r package_dir; do
          [ -n "$package_dir" ] || continue
          work_package_dir="$(ensure_writable_dart_package "$package_dir")"
          mkdir -p "$work_package_dir/third_party/bin/android/arm64" "$work_package_dir/third_party/bin/android/x64"
          tar -xzf ${llamadartNativeAndroidArm64} -C "$work_package_dir/third_party/bin/android/arm64"
          tar -xzf ${llamadartNativeAndroidX64} -C "$work_package_dir/third_party/bin/android/x64"
          patch -p1 -d "$work_package_dir" < ${./llamadart-offline-bundles.patch}
          substituteInPlace "$work_package_dir/hook/build.dart" \
            --replace-fail '@llamadartNativeAndroidArm64@' '${llamadartNativeAndroidArm64}' \
            --replace-fail '@llamadartNativeAndroidX64@' '${llamadartNativeAndroidX64}' \
            --replace-fail '@litertLMNativeAndroidArm64@' '${litertLMNativeAndroidArm64}' \
            --replace-fail '@litertLMNativeAndroidX64@' '${litertLMNativeAndroidX64}'
        done < <(${python3}/bin/python3 - <<'PY'
        import json
        import urllib.parse

        with open(".dart_tool/package_config.json") as f:
            data = json.load(f)

        for package in data.get("packages", []):
            if package.get("name") != "llamadart":
                continue
            root_uri = package.get("rootUri", "")
            if root_uri.startswith("file://"):
                print(urllib.parse.unquote(root_uri[len("file://"):]))
            elif root_uri.startswith("/"):
                print(root_uri)
        PY
        )
      '';

      buildPhase = ''
        runHook preBuild
        flutter build apk --release --no-pub --target-platform android-arm64 --build-number=${lib.last (lib.splitString "+" finalAttrs.version)}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        mv build/app/outputs/flutter-apk/app-release.apk \
          "$out/meshcore-open.apk"
        runHook postInstall
      '';

      meta = with lib; {
        sourceProvenance = with sourceTypes; [ fromSource ];
        description = "MeshCore Open Android client built from source";
        homepage = "https://github.com/jade-on-mesh/meshcore-open-tak";
        license = licenses.mit;
        platforms = platforms.unix;
      };
    });
in
mk-apk-package {
  inherit appPackage;
  mainApk = "meshcore-open.apk";
  signScriptName = "sign-meshcore-open";
  fdroid = {
    appId = "com.meshcore.meshcore_open";
    metadataYml = ''
      Categories:
        - Internet
      License: MIT
      SourceCode: https://github.com/jade-on-mesh/meshcore-open-tak
      IssueTracker: https://github.com/jade-on-mesh/meshcore-open-tak/issues
      AutoName: MeshCore Open
      Summary: Mesh networking client for MeshCore devices
      Description: |-
        MeshCore Open is an open-source client for MeshCore LoRa mesh
        networking devices, supporting messaging, channels, maps, and
        device management.
    '';
  };
}
