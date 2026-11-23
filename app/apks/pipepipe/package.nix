{
  mk-apk-package,
  lib,
  jdk17_headless,
  jdk25_headless,
  gradle_9_5_1,
  stdenv,
  buildGradlePackage,
  fetchFromGitHub,
  writableTmpDirAsHomeHook,
  androidSdkBuilder,
  writeShellScriptBin,
  git,
  curl,
  jq,
}:
let
  appPackage =
    let
      androidSdk = androidSdkBuilder (s: [
        s.cmdline-tools-latest
        s.platform-tools
        s."platforms-android-37-0"
        s."build-tools-37-0-0"
        s."build-tools-36-0-0"
      ]);

      gradle = gradle_9_5_1;
      # Tools used by passthru.updateScript to resolve upstream tags.
      updatePath = lib.makeBinPath [
        git
        curl
        jq
      ];
    in
    buildGradlePackage (finalAttrs: {
      pname = "pipepipe";
      version = "5.6.0";

      src = stdenv.mkDerivation {
        name = "pipepipe-src";
        src = fetchFromGitHub {
          owner = "InfinityLoop1308";
          repo = "PipePipe";
          tag = "v${finalAttrs.version}";
          hash = "sha256-exHSfO4HEXr2vAXYaa+GeRtsyVsXPWe1iDEUs49xFp0=";
        };
        clientSrc = fetchFromGitHub {
          owner = "InfinityLoop1308";
          repo = "PipePipeClient";
          rev = "43ef494c1a1792a774c223e1982ff1e794c49017";
          hash = "sha256-y5oges/vh/hFPgEIZ06Zmgih9c7Q4LSIH3aoj0pZ0HI=";
        };
        extractorSrc = fetchFromGitHub {
          owner = "InfinityLoop1308";
          repo = "PipePipeExtractor";
          rev = "e9818f8ef16d3720107c51f6ee157aecb1da2b70";
          hash = "sha256-0QJmxFjcHqC7c9VVAPcb18dIZDD/AOpLj0BzfEjn078=";
        };
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -a "$clientSrc"/. "$out"/
          chmod -R u+w "$out"
          mkdir -p "$out/PipePipeExtractor"
          cp -a "$extractorSrc"/* "$out/PipePipeExtractor/"
          substituteInPlace "$out/settings.gradle" \
            --replace-fail "includeBuild('../PipePipeExtractor')" "includeBuild('./PipePipeExtractor')" \
            --replace-warn "id 'org.gradle.toolchains.foojay-resolver-convention' version '1.0.0'" ""
          runHook postInstall
        '';
      };

      gradleBuildFlags = [ ":app:assembleRelease" ];
      lockFile = ./gradle.lock;
      buildJdk = jdk25_headless;
      nativeBuildInputs = [
        gradle
        jdk17_headless
        jdk25_headless
        writableTmpDirAsHomeHook
      ];

      env = {
        JAVA_HOME = jdk25_headless;
        ANDROID_HOME = "${androidSdk}/share/android-sdk";
        ANDROID_SDK_ROOT = "${androidSdk}/share/android-sdk";
        ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = "${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2";
      };

      gradleFlags = [
        "-Dandroid.builder.sdkDownload=false"
        "-Dorg.gradle.java.home=${jdk25_headless.passthru.home}"
        "-Dorg.gradle.java.installations.auto-download=false"
        "-Dorg.gradle.java.installations.paths=${jdk17_headless.passthru.home},${jdk25_headless.passthru.home}"
        "-Dandroid.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
        "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
      ];

      preBuild = lib.optionalString stdenv.hostPlatform.isDarwin ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export ANDROID_USER_HOME="$HOME/.android"
        export GRADLE_USER_HOME="$HOME/.gradle"
        mkdir -p "$ANDROID_USER_HOME" "$GRADLE_USER_HOME"
        export GRADLE_OPTS="''${GRADLE_OPTS:+$GRADLE_OPTS }-Duser.home=$HOME"
      '';

      installPhase = ''
        runHook preInstall
        apk_dir="app/build/outputs/apk/release"
        apk_name="$(sed -n 's/.*"outputFile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$apk_dir/output-metadata.json" | head -n 1)"
        test -n "$apk_name"
        apk_path="$apk_dir/$apk_name"
        test -f "$apk_path"
        install -Dm644 "$apk_path" "$out/pipepipe.apk"
        runHook postInstall
      '';

      passthru = {
        inherit androidSdk;
        # `nix-update` cannot bump this package: the tag only pins the
        # PipePipeClient/PipePipeExtractor submodule commits, and the buildable
        # source is a combination of those two repositories. Resolve the new
        # tag and its submodule commits from the PipePipe repository instead.
        updateScript = writeShellScriptBin "update-pipepipe" ''
          set -euo pipefail
          package_file="app/apks/pipepipe/package.nix"
          package_attr=".#apk_pipepipe"
          fake_hash="${lib.fakeHash}"
          export PATH="${updatePath}:$PATH"
          . "${../_shared/update-script-helpers.sh}"

          tag="$(git ls-remote --tags https://github.com/InfinityLoop1308/PipePipe.git 'refs/tags/v*' \
            | sed 's#.*refs/tags/##' | grep -Ev -- '\^\{|-(beta|alpha|rc)' \
            | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1)"
          test -n "$tag"
          version="''${tag#v}"
          replace_literal "$(nix eval --raw "$package_attr.version")" "$version"
          # `src` is the combined client/extractor tree; `src.src` is the
          # PipePipe tag tarball whose hash tracks the version.
          refresh_fod_hash src.src

          tree="$(curl -fsSL "https://api.github.com/repos/InfinityLoop1308/PipePipe/git/trees/$tag")"
          replace_literal \
            "$(nix eval --raw "$package_attr.src.clientSrc.rev")" \
            "$(jq -r '.tree[] | select(.path == "PipePipeClient") | .sha' <<<"$tree")"
          replace_literal \
            "$(nix eval --raw "$package_attr.src.extractorSrc.rev")" \
            "$(jq -r '.tree[] | select(.path == "PipePipeExtractor") | .sha' <<<"$tree")"
          refresh_fod_hash src.clientSrc
          refresh_fod_hash src.extractorSrc

          refresh_gradle_lock ${gradle.version} app/apks/pipepipe/gradle.lock
        '';
      };

      meta = with lib; {
        description = "PipePipe";
        homepage = "https://github.com/InfinityLoop1308/PipePipe";
        license = licenses.gpl3Plus;
        platforms = platforms.unix;
      };
    });
in
mk-apk-package {
  inherit appPackage;
  mainApk = "pipepipe.apk";
  signScriptName = "sign-pipepipe";
  fdroid = {
    appId = "InfinityLoop1309.NewPipeEnhanced";
    metadataYml = ''
      Categories:
        - Multimedia
      License: GPL-3.0-or-later
      SourceCode: https://github.com/InfinityLoop1308/PipePipe
      IssueTracker: https://github.com/InfinityLoop1308/PipePipe/issues
      Changelog: https://github.com/InfinityLoop1308/PipePipe/releases
      AutoName: PipePipe
      Summary: A FLOSS Android app to let you browse YouTube, NicoNico and BiliBili ad-free.
      Description: |-
        PipePipe is a FLOSS Android app to let you browse YouTube, NicoNico and BiliBili ad-free.
    '';
  };
}
