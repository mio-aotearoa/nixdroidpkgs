{
  mk-apk-package,
  lib,
  jdk17_headless,
  gradle_9_3_1,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  unzip,
  writableTmpDirAsHomeHook,
  androidSdkBuilder,
  writeShellScriptBin,
  nix-update,
}:
let
  version = "0.1.7";

  # Upstream ships QEMU engines, Turnip, and the Apple-setup helper VM outside git
  # (pull-libs.sh / pull-libs26.sh / pull-setup.sh). Reuse the matching release APK
  # as a fixed-output source for those binaries; Java/CMake still build from tag.
  # updateScript refreshes this hash via passthru.updateDeps after nix-update.
  prebuiltsApk = fetchurl {
    url = "https://github.com/alpersamur3/asoft-ios-android/releases/download/v${version}/ASoftware-iOS-Android-${version}.apk";
    hash = "sha256-Vh3Sj3uUPkWm87X9kk/aoxNVwSoKhotJHmN2c2TjjqQ=";
  };

  androidSdk = androidSdkBuilder (s: [
    s.cmdline-tools-latest
    s.platform-tools
    s.platforms-android-35
    s.platforms-android-36
    s.build-tools-35-0-0
    s.build-tools-36-0-0
    s.ndk-29-0-14206865
    s.cmake-3-22-1
  ]);

  gradle = gradle_9_3_1;
  androidSdkRoot = "${androidSdk}/share/android-sdk";
  ndkVersion = "29.0.14206865";
  aapt2 = "${androidSdkRoot}/build-tools/36.0.0/aapt2";
  jdkHome = jdk17_headless.passthru.home;

  appPackage = stdenv.mkDerivation (finalAttrs: {
    pname = "asoft-ios";
    inherit version;

    src = fetchFromGitHub {
      owner = "alpersamur3";
      repo = "asoft-ios-android";
      tag = "v${finalAttrs.version}";
      hash = "sha256-0oQJNn3IIyCPs7pIkBC38hw2WsMA9inJga5dkoLmNEw=";
    };

    gradleBuildTask = ":app:assembleRelease";
    gradleUpdateTask = finalAttrs.gradleBuildTask;

    mitmCache = gradle.fetchDeps {
      inherit (finalAttrs) pname;
      pkg = finalAttrs.finalPackage;
      data = ./asoft-ios_deps.json;
      silent = false;
      useBwrap = false;
    };

    nativeBuildInputs = [
      androidSdk
      gradle
      jdk17_headless
      unzip
      writableTmpDirAsHomeHook
    ];

    env = {
      JAVA_HOME = jdkHome;
      ANDROID_HOME = androidSdkRoot;
      ANDROID_SDK_ROOT = androidSdkRoot;
      ANDROID_NDK_HOME = "${androidSdkRoot}/ndk/${ndkVersion}";
      ANDROID_NDK_ROOT = "${androidSdkRoot}/ndk/${ndkVersion}";
      ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = aapt2;
    };

    postPatch = ''
      # Upstream pins a Windows Android Studio JBR path.
      substituteInPlace gradle.properties \
        --replace-fail 'org.gradle.java.home=C:\\Program Files\\Android\\Android Studio\\jbr' ""

      substituteInPlace app/build.gradle \
        --replace-fail "ndkVersion '29.0.13846066'" "ndkVersion '${ndkVersion}'"
    '';

    preConfigure = ''
      export ANDROID_USER_HOME="$HOME/.android"
      if [ -z "''${GRADLE_USER_HOME:-}" ]; then
        export GRADLE_USER_HOME="$HOME/.gradle"
      fi
      mkdir -p "$ANDROID_USER_HOME" "$GRADLE_USER_HOME"
      echo "sdk.dir=${androidSdkRoot}" > local.properties
      echo "cmake.dir=${androidSdkRoot}/cmake/3.22.1" >> local.properties

      # QEMU engines + Termux closure, iOS 26 Turnip stack, and Apple-setup assets
      # are gitignored; unpack them from the same-version release APK.
      extract="$(mktemp -d)"
      unzip -q ${prebuiltsApk} \
        'lib/arm64-v8a/*' \
        'assets/helper/*' \
        'assets/xnu/*' \
        'assets/setup/*' \
        -d "$extract"

      jni="app/src/main/jniLibs/arm64-v8a"
      jni26="app/src/main/jniLibs26/arm64-v8a"
      mkdir -p "$jni" "$jni26" app/src/main/assets
      for f in "$extract"/lib/arm64-v8a/*; do
        name="$(basename "$f")"
        case "$name" in
          # Built here via CMake / Conscrypt AAR — do not keep release copies.
          libgpucheck.so|librender.so|libunpack.so|libconscrypt_jni.so) ;;
          libqemu26.so|lib_libvulkan.so.so|lib_libvulkan_freedreno.so.so)
            mv "$f" "$jni26/"
            ;;
          *)
            mv "$f" "$jni/"
            ;;
        esac
      done
      rm -rf app/src/main/assets/helper app/src/main/assets/xnu app/src/main/assets/setup
      mv "$extract"/assets/helper "$extract"/assets/xnu "$extract"/assets/setup \
        app/src/main/assets/
      chmod -R u+w app/src/main/jniLibs app/src/main/jniLibs26 app/src/main/assets
      rm -rf "$extract"
    '';

    gradleFlags = [
      "--no-daemon"
      "-Dorg.gradle.java.home=${jdkHome}"
      "-Dorg.gradle.java.installations.auto-download=false"
      "-Dorg.gradle.java.installations.paths=${jdkHome}"
      "-Dandroid.aapt2FromMavenOverride=${aapt2}"
      "-Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2}"
    ];

    installPhase = ''
      runHook preInstall
      apk_path=""
      for candidate in \
        app/build/outputs/apk/release/app-release-unsigned.apk \
        app/build/outputs/apk/release/app-release.apk; do
        if [ -f "$candidate" ]; then
          apk_path="$candidate"
          break
        fi
      done
      test -n "$apk_path"
      install -Dm644 "$apk_path" "$out/asoft-ios.apk"
      runHook postInstall
    '';

    passthru = {
      inherit prebuiltsApk;
      updateDeps = [ "prebuiltsApk" ];
      updateScript = writeShellScriptBin "update-asoft-ios" ''
        set -euo pipefail

        package_file="app/apks/asoft-ios/package.nix"
        package_attr=".#apk_asoft-ios"
        fake_hash="${lib.fakeHash}"

        . "${../_shared/update-script-helpers.sh}"

        ${lib.getExe nix-update} --flake --src-only --version-regex='^v?([0-9]+\.[0-9]+\.[0-9]+)$' apk_asoft-ios

        refresh_update_deps ${lib.concatStringsSep " " finalAttrs.passthru.updateDeps}

        refresh_mitm_cache
      '';
    };

    meta = with lib; {
      sourceProvenance = with sourceTypes; [
        fromSource
        binaryNativeCode
      ];
      description = "Run iOS 16 (and preview iOS 26 / watchOS) in an Android app";
      homepage = "https://github.com/alpersamur3/asoft-ios-android";
      license = licenses.mit;
      platforms = platforms.unix;
    };
  });
in
mk-apk-package {
  inherit appPackage;
  mainApk = "asoft-ios.apk";
  signScriptName = "sign-asoft-ios";
  fdroid = {
    appId = "com.asoft.ios";
    metadataYml = ''
      AntiFeatures:
        NonFreeNet:
          en-US: Downloads iOS images and related files from Apple and GitHub during setup.
      Categories:
        - System
      License: MIT
      SourceCode: https://github.com/alpersamur3/asoft-ios-android
      IssueTracker: https://github.com/alpersamur3/asoft-ios-android/issues
      Changelog: https://github.com/alpersamur3/asoft-ios-android/releases
      AutoName: ASoftware iOS
      Summary: iOS 16 (and preview iOS 26 / watchOS) on stock Android
      Description: |-
        ASoftware iOS for Android runs iOS 16 in an Android app on a stock,
        locked phone using QEMU plus a native EL0 engine. Preview support for
        iOS 26 and watchOS is included on supported Adreno GPUs.
        The app Java and CMake natives are built from the v${version} tag;
        QEMU engines, Turnip, and Apple-setup helper assets come from the
        matching upstream release APK (those binaries are not in git).
    '';
  };
}
