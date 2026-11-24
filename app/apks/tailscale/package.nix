{
  mk-apk-package,
  lib,
  stdenv,
  stdenvNoCC,
  fetchFromGitHub,
  androidSdkBuilder,
  gradle_9_6_1,
  go_1_27,
  jdk21_headless,
  writableTmpDirAsHomeHook,
  gnumake,
  zip,
  unzip,
  cacert,
  patch,
  git,
  writeShellScriptBin,
  nix-update,
}:
let
  appPackage =
    let
      version = "1.106.0-t959d056b4-g450635cea";

      src = fetchFromGitHub {
        owner = "tailscale";
        repo = "tailscale-android";
        tag = version;
        hash = "sha256-jgVO5d1DYRopkNK0KvytbnjHy8w6LnHByhZzvi8AV5s=";
      };

      tailscaleSrc = fetchFromGitHub {
        owner = "tailscale";
        repo = "tailscale";
        rev = "9ff10465e331030959456bd776e8b4e9e8b2c407";
        hash = "sha256-NZcRsXN8PFABvmQ/1c0CQ74BowRRCc90/xj6g9qLQ3Y=";
      };

      xMobileSrc = fetchFromGitHub {
        owner = "golang";
        repo = "mobile";
        # https://github.com/tailscale/tailscale-android/blob/5c5030c5434dc465d1e277b19222456544553482/go.mod#L7
        rev = "81131f6468ab";
        hash = "sha256-/WelLIFKCHuMZnRnaWFvBo8wZB33fRJurbbFEs16tG0=";
      };

      goModCache = stdenvNoCC.mkDerivation {
        pname = "tailscale-go-mod-cache";
        inherit version src;

        nativeBuildInputs = [
          go_1_27
          writableTmpDirAsHomeHook
          cacert
          patch
          git
        ];

        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        # Update hash to trigger rebuild with internet access
        outputHash = "sha256-CrmcKzGbl9r1buTfuPhUhdWDRQZtyweyPUAEFZvDsqo=";

        dontConfigure = true;
        dontFixup = true;

        buildPhase = ''
          runHook preBuild

          export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
          export GOTOOLCHAIN=local
          export GOPATH="$TMPDIR/go"
          export GOCACHE="$TMPDIR/go-build-cache"
          export GOMODCACHE="$TMPDIR/go-mod-cache"
          export GOPROXY=https://proxy.golang.org,direct
          export GOSUMDB=sum.golang.org
          export GOFLAGS=-buildvcs=false

          cp -R "$src" source
          chmod -R u+w source
          cd source

          # Aggressively patch go.mod files to use the available go version
          find . -name "go.mod" -execdir go mod edit -go=${go_1_27.version} -toolchain=none {} \;

          cp -R ${tailscaleSrc} tailscale-module
          chmod -R u+w tailscale-module
          go mod edit -go=${go_1_27.version} -toolchain=none tailscale-module/go.mod
          go mod edit -replace=tailscale.com=./tailscale-module

          cp -R ${xMobileSrc} x-mobile
          chmod -R u+w x-mobile
          patch -d x-mobile -p1 < ${./gomobile-avoid-empty-go-mod.patch}
          go mod edit -replace=golang.org/x/mobile=./x-mobile

          go mod download

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          chmod -R u+w "$TMPDIR/go-mod-cache"
          mv "$TMPDIR/go-mod-cache" "$out"
          runHook postInstall
        '';
      };

      androidSdk = androidSdkBuilder (s: [
        s.cmdline-tools-latest
        s.platform-tools
        s.platforms-android-37-0
        s.platforms-android-36
        s.platforms-android-34
        s.build-tools-37-0-0
        s.build-tools-36-0-0
        s.build-tools-34-0-0
        s.ndk-27-3-13750724
      ]);

      gradle = gradle_9_6_1;
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "tailscale";
      inherit version src;

      passthru = {
        inherit goModCache tailscaleSrc xMobileSrc;

        # The Go module cache covers this source tree's go.mod, so it has to be
        # refreshed whenever a new release changes the module graph.
        updateDeps = [ "goModCache" ];

        updateScript = writeShellScriptBin "update-tailscale" ''
          set -euo pipefail
          package_file="app/apks/tailscale/package.nix"
          package_attr=".#apk_tailscale"
          fake_hash="${lib.fakeHash}"

          . "${../_shared/update-script-helpers.sh}"

          ${lib.getExe nix-update} --flake --src-only apk_tailscale

          src="$(nix build .#apk_tailscale.src --no-link --print-out-paths)"

          # tailscale-android's go.mod pins the tailscale.com module. Stable
          # builds pin a release tag; unstable builds a pseudo-version whose
          # last segment is the commit.
          ts_ref="$(sed -n 's/^[[:space:]]*tailscale\.com \([^[:space:]]*\)$/\1/p' "$src/go.mod" | head -n 1)"
          [[ -n "$ts_ref" ]] || {
            echo "error: no tailscale.com require line in $src/go.mod" >&2
            exit 1
          }

          if [[ "$ts_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Annotated tags point at a tag object; use its peeled commit.
            tag_refs="$(${lib.getExe git} ls-remote --tags https://github.com/tailscale/tailscale.git "refs/tags/$ts_ref" "refs/tags/$ts_ref^{}")"
            ts_rev="$(awk -v ref="refs/tags/$ts_ref^{}" '$2 == ref { print $1 }' <<<"$tag_refs")"
            [[ -n "$ts_rev" ]] || ts_rev="$(awk -v ref="refs/tags/$ts_ref" '$2 == ref { print $1 }' <<<"$tag_refs")"
          else
            ts_rev="$(sed -n 's/.*-\([0-9a-f]\{12\}\)$/\1/p' <<<"$ts_ref")"
          fi
          [[ -n "$ts_rev" ]] || {
            echo "error: could not resolve tailscale.com $ts_ref to a commit" >&2
            exit 1
          }

          block_rev() {
            awk -v block="$1 = fetchFromGitHub {" '
              index($0, block) { f = 1 }
              f && /rev = "/ {
                split($0, fields, "\"")
                print fields[2]
                exit
              }
            ' "$package_file"
          }

          old_ts_rev="$(block_rev tailscaleSrc)"
          if [[ "$ts_rev" != "$old_ts_rev" ]]; then
            replace_literal "rev = \"$old_ts_rev\";" "rev = \"$ts_rev\";"
            refresh_fod_hash tailscaleSrc
          else
            echo "  tailscaleSrc: unchanged"
          fi

          xm_ref="$(sed -n 's/^[[:space:]]*golang\.org\/x\/mobile \([^[:space:]]*\)$/\1/p' "$src/go.mod" | head -n 1)"
          xm_rev="$(sed -n 's/.*-\([0-9a-f]\{12\}\)$/\1/p' <<<"$xm_ref")"
          if [[ -n "$xm_rev" ]]; then
            old_xm_rev="$(block_rev xMobileSrc)"
            if [[ "$xm_rev" != "$old_xm_rev" ]]; then
              replace_literal "rev = \"$old_xm_rev\";" "rev = \"$xm_rev\";"
              refresh_fod_hash xMobileSrc
            else
              echo "  xMobileSrc: unchanged"
            fi
          fi

          refresh_update_deps ${lib.concatStringsSep " " finalAttrs.passthru.updateDeps}
          refresh_mitm_cache
        '';
      };

      gradleBuildTask = "assembleRelease";
      gradleUpdateTask = finalAttrs.gradleBuildTask;

      __darwinAllowLocalNetworking = true;
      __noChroot = stdenv.hostPlatform.isDarwin;

      mitmCache = gradle.fetchDeps {
        pname = "tailscale";
        pkg = finalAttrs.finalPackage;
        data = ./tailscale_deps.json;
        silent = false;
        useBwrap = false;
      };

      nativeBuildInputs = [
        gradle
        go_1_27
        gnumake
        jdk21_headless
        writableTmpDirAsHomeHook
        zip
        unzip
      ];

      env = {
        JAVA_HOME = jdk21_headless.passthru.home;
        ANDROID_HOME = "${androidSdk}/share/android-sdk";
        ANDROID_SDK_ROOT = "${androidSdk}/share/android-sdk";
        ANDROID_NDK_ROOT = "${androidSdk}/share/android-sdk/ndk/27.3.13750724";
        NDK_ROOT = "${androidSdk}/share/android-sdk/ndk/27.3.13750724";
        ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = "${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2";
      };

      preBuild = ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME/.android" "$HOME/.gradle" "$HOME/.cache"
        export ANDROID_USER_HOME="$HOME/.android"
        export GRADLE_USER_HOME="$HOME/.gradle"
        export GRADLE_OPTS="''${GRADLE_OPTS:+$GRADLE_OPTS }-Duser.home=$HOME -Dandroid.user.home=$ANDROID_USER_HOME"

        patchShebangs tool build-tags.sh version-ldflags.sh

        export GOCACHE="$TMPDIR/go-cache"
        export GOPATH="$TMPDIR/go"
        export GOMODCACHE="$PWD/.gomodcache"
        cp -R ${goModCache} "$GOMODCACHE"
        chmod -R u+w "$GOMODCACHE"
        export GOPROXY=off
        export GOSUMDB=off
        export GOTOOLCHAIN=local

        # Aggressively patch go.mod files to use the available go version
        find . -name "go.mod" -execdir go mod edit -go=${go_1_27.version} -toolchain=none {} \;

        find "$GOMODCACHE" -name go.mod -print | while read -r gomod; do
          chmod u+w "$(dirname "$gomod")" "$gomod"
          go mod edit -go=${go_1_27.version} -toolchain=none "$gomod"
        done

        cp -R ${tailscaleSrc} tailscale-module
        chmod -R u+w tailscale-module
        go mod edit -go=${go_1_27.version} -toolchain=none tailscale-module/go.mod
        go mod edit -replace=tailscale.com=./tailscale-module

        cp -R ${xMobileSrc} x-mobile
        chmod -R u+w x-mobile
        patch -d x-mobile -p1 < ${./gomobile-avoid-empty-go-mod.patch}
        go mod edit -replace=golang.org/x/mobile=./x-mobile

        export TOOLCHAINDIR="${go_1_27}/share/go"
        export TOOLCHAIN_DIR="$TOOLCHAINDIR"
        export PATH="$TOOLCHAINDIR/bin:$PATH"

        # gomobile still falls back to GOPATH-style package resolution while
        # building the generated gobind wrapper. Mirror the resolved module graph
        # into GOPATH/src so those imports remain available in GOPATH mode.
        mkdir -p "$GOPATH/src/github.com/tailscale" "$GOPATH/src/golang.org/x"
        ln -s "$PWD" "$GOPATH/src/github.com/tailscale/tailscale-android"
        ln -s "$PWD/tailscale-module" "$GOPATH/src/tailscale.com"
        ln -s "$PWD/x-mobile" "$GOPATH/src/golang.org/x/mobile"
        find "$GOMODCACHE" -name go.mod -print | while read -r gomod; do
          module_dir="$(dirname "$gomod")"
          rel_path="''${module_dir#$GOMODCACHE/}"
          module_path="''${rel_path%@*}"
          case "$module_path" in
            golang.org/toolchain*) continue ;;
          esac
          mkdir -p "$GOPATH/src/$(dirname "$module_path")"
          if [ ! -e "$GOPATH/src/$module_path" ]; then
            ln -s "$module_dir" "$GOPATH/src/$module_path"
          fi
        done

        cat > tailscale.version <<EOF
        VERSION_LONG="${version}"
        VERSION_SHORT="${version}"
        VERSION_GIT_HASH=""
        VERSION_EXTRA_HASH=""
        EOF

        cat > android/local.properties <<EOF
        sdk.dir=${androidSdk}/share/android-sdk
        EOF

        substituteInPlace android/build.gradle.kts \
          --replace-fail 'ndkVersion = "23.1.7779620"' 'ndkVersion = "27.3.13750724"'

        substituteInPlace Makefile \
          --replace-fail 'ndk;23.1.7779620' 'ndk;27.3.13750724'

        cat >> android/gradle.properties <<EOF
        org.gradle.jvmargs=-Xmx4096m -Duser.home=$HOME -Dandroid.user.home=$HOME/.android
        systemProp.user.home=$HOME
        systemProp.android.user.home=$HOME/.android
        android.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2
        org.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2
        EOF

        make env
        make libtailscale
      '';

      gradleFlags = [
        "--no-daemon"
        "--no-watch-fs"
        "-Dorg.gradle.vfs.watch=false"
        "-xlintVitalRelease"
        "-p"
        "android"
        "-Dorg.gradle.java.installations.auto-download=false"
        "-Dorg.gradle.java.installations.paths=${finalAttrs.env.JAVA_HOME}"
        "-Dandroid.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
        "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/share/android-sdk/build-tools/37.0.0/aapt2"
      ];

      installPhase = ''
        runHook preInstall
        install -Dm644 android/build/outputs/apk/release/android-release-unsigned.apk "$out/tailscale.apk"
        runHook postInstall
      '';

      meta = with lib; {
        sourceProvenance = with sourceTypes; [ fromSource ];
        description = "Tailscale Android client built from source";
        homepage = "https://github.com/tailscale/tailscale-android";
        license = licenses.bsd3;
        platforms = platforms.unix;
      };
    });
in
mk-apk-package {
  inherit appPackage;
  mainApk = "tailscale.apk";
  signScriptName = "sign-tailscale";
  fdroid = {
    appId = "com.tailscale.ipn";
    metadataYml = ''
      Categories:
        - Internet
      License: BSD-3-Clause
      WebSite: https://tailscale.com/
      SourceCode: https://github.com/tailscale/tailscale-android
      IssueTracker: https://github.com/tailscale/tailscale-android/issues
      Changelog: https://github.com/tailscale/tailscale-android/releases
      AutoName: Tailscale
      Summary: Mesh VPN client
      Description: |-
        Tailscale is a mesh VPN client for connecting devices over a
        private WireGuard-based network.
        This package is built from source from the upstream
        tailscale-android repository.
    '';
  };
}
