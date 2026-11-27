{
  lib,
  stdenv,
  darwin,
  fetchFromGitHub,
  gradle_8_12,
  androidSdkBuilder,
  jdk17_headless,
  writableTmpDirAsHomeHook,
  nix-update-script,
}:
let
  version = "1.7.0";

  androidSdk = androidSdkBuilder (s: [
    s.cmdline-tools-latest
    s.platform-tools
    s.platforms-android-34
    s.platforms-android-35
    s.build-tools-34-0-0
    s.build-tools-35-0-0
    s.ndk-26-0-10792818
    s.ndk-29-0-14206865
    s.cmake-4-1-2
  ]);
  androidSdkRoot = "${androidSdk}/share/android-sdk";
  aapt2 = "${androidSdkRoot}/build-tools/35.0.0/aapt2";

  gradle = gradle_8_12;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "biliroaming";
  inherit version;

  src = fetchFromGitHub {
    owner = "yujincheng08";
    repo = "BiliRoaming";
    tag = "v${version}";
    hash = "sha256-6ragIxkxok5d71+424BVP4MMVlm9M0qYC0KXLu7zX5U=";
    fetchSubmodules = true;
    gitConfigFile = lib.toFile "gitconfig" ''
      [url "https://github.com/"]
        insteadOf = git@github.com:
    '';
  };

  postUnpack = ''
    substituteInPlace "$sourceRoot/app/build.gradle.kts" \
      --replace-fail \
        'val appVerCode = jgit.repo()?.commitCount("refs/remotes/origin/master") ?: 0' \
        'val appVerCode = jgit.repo()?.commitCount("refs/remotes/origin/master") ?: 1'
  '';

  postPatch = ''
    find . -name "*.orig" -delete
    substituteInPlace \
      app/src/main/jni/CMakeLists.txt \
      app/src/main/jni/dex_builder/CMakeLists.txt \
      --replace-fail 'cmake_minimum_required(VERSION 3.4.1)' 'cmake_minimum_required(VERSION 3.5)'
  '';

  gradleBuildTask = ":app:assembleRelease";
  gradleUpdateTask = finalAttrs.gradleBuildTask;
  passthru.updateScript = nix-update-script { };
  __darwinAllowLocalNetworking = true;
  __noChroot = stdenv.hostPlatform.isDarwin;

  mitmCache = gradle.fetchDeps {
    inherit (finalAttrs) pname;
    pkg = finalAttrs.finalPackage;
    data = ./biliroaming_deps.json;
    silent = false;
    useBwrap = false;
  };

  nativeBuildInputs = [
    gradle
    jdk17_headless
    writableTmpDirAsHomeHook
  ]
  ++ lib.optional stdenv.hostPlatform.isDarwin darwin.system_cmds;

  env = {
    JAVA_HOME = jdk17_headless.passthru.home;
    ANDROID_HOME = androidSdkRoot;
    ANDROID_SDK_ROOT = androidSdkRoot;
    ANDROID_NDK_ROOT = "${androidSdkRoot}/ndk/29.0.14206865";
    ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = aapt2;
  };

  preConfigure = ''
    export HOME="$TMPDIR/home"
    export ANDROID_USER_HOME="$HOME/.android"
    export GRADLE_USER_HOME="$TMPDIR/gradle-home"
    mkdir -p "$HOME" "$ANDROID_USER_HOME" "$GRADLE_USER_HOME"
    echo "sdk.dir=${androidSdkRoot}" > local.properties

    cat >> gradle.properties <<EOF
    org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g
    EOF
  '';

  gradleFlags = [
    "--no-daemon"
    "-Dorg.gradle.java.installations.auto-download=false"
    "-Dorg.gradle.java.installations.paths=${jdk17_headless.passthru.home}"
    "-Dandroid.aapt2FromMavenOverride=${aapt2}"
    "-Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2}"
  ];

  installPhase = ''
    runHook preInstall
    apk_dir="app/build/outputs/apk/release"
    apk_name="$(sed -n 's/.*"outputFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$apk_dir/output-metadata.json" | head -n 1)"
    test -n "$apk_name"
    apk_path="$apk_dir/$apk_name"
    test -f "$apk_path"
    install -Dm644 "$apk_path" "$out/biliroaming.apk"
    runHook postInstall
  '';

  meta = with lib; {
    description = "BiliRoaming Xposed module built from the latest commit";
    homepage = "https://github.com/yujincheng08/BiliRoaming";
    license = licenses.gpl3Only;
    platforms = platforms.unix;
  };
})
