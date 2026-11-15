{
  agp-resolution,
  mk-apk-package,
  overrides-fromsrc,
  buildGradlePackage,
  lib,
  jdk21_headless,
  jdk17_headless,
  gradle_9_7_0,
  fetchFromGitea,

  writableTmpDirAsHomeHook,
  androidSdkBuilder,
  git,
  overrides-fromsrc-updated,
  stdenv,
  nix-update,
  writeShellScriptBin,
}:
let
  version = "1.3.3";

  src = fetchFromGitea {
    domain = "codeberg.org";
    owner = "Sunup";
    repo = "android";
    name = "sunup-${version}-source";
    tag = version;
    hash = "sha256-o7RCiMtQjui6xExJOb2F/yntUQlMTt0UpDV+3epz0LY=";
  };

  androidSdk = androidSdkBuilder (s: [
    s.cmdline-tools-latest
    s.platform-tools
    s.platforms-android-36
    s.platforms-android-37-0
    s.build-tools-36-0-0
    s.build-tools-37-0-0
  ]);

  gradle = gradle_9_7_0;

  appPackage = buildGradlePackage rec {
    pname = "sunup";
    inherit version src gradle;

    lockFile = ./gradle.lock;
    overrides = overrides-fromsrc-updated;
    buildJdk = jdk21_headless;

    postPatch = ''
      rm -f gradle/verification-metadata.xml
    '';

    nativeBuildInputs = [
      androidSdk
      gradle
      jdk21_headless

      writableTmpDirAsHomeHook
      git
    ];

    dontUseGradleConfigure = true;

    __darwinAllowLocalNetworking = true;
    __noChroot = stdenv.hostPlatform.isDarwin;

    env = {
      JAVA_HOME = jdk21_headless.passthru.home;
      ANDROID_HOME = "${androidSdk}/share/android-sdk";
      ANDROID_SDK_ROOT = "${androidSdk}/share/android-sdk";
      ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = "${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2";
    };

    preConfigure = ''
      export ANDROID_USER_HOME="$HOME/.android"
      export ANDROID_SDK_HOME="$HOME"
      export ANDROID_PREFS_ROOT="$HOME"
      export GRADLE_USER_HOME="$HOME/.gradle"
      export TERM=dumb
      mkdir -p "$ANDROID_USER_HOME"
      echo "sdk.dir=${androidSdk}/share/android-sdk" > local.properties
      printf "\norg.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=1024m\n" >> gradle.properties
      gradleFlagsArray+=(--no-daemon --no-watch-fs -Dorg.gradle.vfs.watch=false --init-script "$gradleInitScript" --offline)
    '';

    gradleFlags = [
      "-x"
      "lintVitalRelease"
      "-Dorg.gradle.java.home=${jdk21_headless.passthru.home}"
      "-Dorg.gradle.java.installations.auto-download=false"
      "-Dorg.gradle.java.installations.paths=${jdk17_headless.passthru.home},${jdk21_headless.passthru.home}"
      "-Dandroid.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
      "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
    ];

    gradleBuildFlags = ":app:assembleRelease";

    passthru.updateScript = writeShellScriptBin "update-sunup" ''
      set -euo pipefail
      package_file="app/apks/sunup/package.nix"
      package_attr=".#apk_sunup"
      fake_hash="${lib.fakeHash}"
      . "${../_shared/update-script-helpers.sh}"
      ${lib.getExe nix-update} --flake --src-only apk_sunup
      refresh_gradle_lock ${gradle.version} app/apks/sunup/gradle.lock
    '';

    installPhase = ''
      runHook preInstall
      apk_path="$(echo app/build/outputs/apk/release/*.apk)"
      install -Dm644 "$apk_path" "$out/sunup.apk"
      runHook postInstall
    '';

    meta = with lib; {
      sourceProvenance = with sourceTypes; [ fromSource ];
      description = "UnifiedPush distributor using a local push gateway";
      homepage = "https://codeberg.org/Sunup/android";
      license = licenses.gpl3Plus;
      platforms = platforms.unix;
    };
  };
in
mk-apk-package {
  inherit appPackage;
  mainApk = "sunup.apk";
  signScriptName = "sign-sunup";
  fdroid = {
    appId = "org.unifiedpush.distributor.sunup";
    metadataYml = ''
      Categories:
        - System
      License: GPL-3.0-or-later
      SourceCode: https://codeberg.org/Sunup/android
      IssueTracker: https://codeberg.org/Sunup/android/issues
      AutoName: Sunup
      Summary: UnifiedPush distributor using a local push gateway
      Description: |-
        Sunup is a UnifiedPush distributor that uses a local push gateway
        to deliver push notifications without relying on Google services.
        This package is built from source.
    '';
  };
}
