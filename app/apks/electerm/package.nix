{
  mk-apk-package,
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs_24,
  cacert,
  gradle_8_14_3,
  jdk21_headless,
  androidSdkBuilder,
  writableTmpDirAsHomeHook,
  writeShellScriptBin,
  nix-update,
  git,
}:
let
  version = "5.15.1";

  src = fetchFromGitHub {
    owner = "electerm";
    repo = "electerm-android";
    tag = "v${version}";
    hash = "sha256-qwJv3lr+wQeggbBsCPCQOapL4ubh0FDvpq5NYSmH+bs=";
  };

  androidSdk = androidSdkBuilder (s: [
    s.cmdline-tools-latest
    s.platform-tools
    s.platforms-android-36
    s.build-tools-36-0-0
    # @capgo/capacitor-file-sharer still pins buildToolsVersion 35.0.0.
    s.build-tools-35-0-0
    # @capawesome/capacitor-nodejs builds a small JNI shim with CMake and links
    # the prebuilt libnode.so, so the plugin needs both an NDK and CMake.
    s.ndk-27-0-12077973
    s.cmake-3-22-1
  ]);

  androidHome = "${androidSdk}/share/android-sdk";
  ndkVersion = "27.0.12077973";

  # https://github.com/electerm/electerm-android/blob/v5.15.1/build/android/android/gradle/wrapper/gradle-wrapper.properties
  gradle = gradle_8_14_3;

  aapt2Path = "${androidHome}/build-tools/36.0.0/aapt2";

  # The Android repo does not vendor the backend: `build/bin/install.js`
  # resolves the tip of electerm-web's default branch on every install and
  # copies that tree's `src/`. Pin the commit so the tree is reproducible;
  # `passthru.updateScript` moves the pin together with the app.
  electermWebSrc = fetchFromGitHub {
    owner = "electerm";
    repo = "electerm-web";
    rev = "9178e08ed83411d5bc6a4b367fe9ca35b6cb186c";
    hash = "sha256-rjjld61SA+UsSrnZLZ1jjxULbDIShFFV1BHT03hKVhQ=";
  };

  # `@capawesome/capacitor-nodejs` downloads these Node.js for Mobile Apps
  # binaries from GitHub from inside its Gradle build. Gradle has no network
  # here, so hand it the store copy through `nodejsMobileAndroidUrl`.
  nodejsMobileAndroid = fetchurl {
    url = "https://github.com/capawesome-team/nodejs-mobile/releases/download/v18.20.4-capawesome.1/nodejs-mobile-v18.20.4-capawesome.1-android.zip";
    hash = "sha256-Gzx5ecga7Imn9Rsprx9IdaXWN3J61uLDks3y4SdxXak=";
  };

  # Both lockfiles resolve fine with a plain `npm ci`; the prefetched-cache
  # route does not, because it silently drops a few registry entries. Install
  # the trees as fixed-output derivations instead.
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
    installNodeModules "electerm-${version}-node-modules" src
      "sha256-MT9xL5wPpYI9pY9hck8djnGl9Khtsw6Zcu1HmOO9v9M=";

  # build/android carries its own lockfile, so it gets its own tree.
  androidNodeModules =
    installNodeModules "electerm-${version}-android-node-modules" "${src}/build/android"
      "sha256-OQpfNtFdCsTQh0nZexe2T2o+woOyYHquZEqKTDJ46Yk=";

  appPackage = stdenv.mkDerivation (finalAttrs: {
    pname = "electerm";
    inherit version src;

    gradleBuildTask = "assembleRelease";
    gradleUpdateTask = finalAttrs.gradleBuildTask;

    mitmCache = gradle.fetchDeps {
      inherit (finalAttrs) pname;
      attrPath = "apk_electerm";
      pkg = finalAttrs.finalPackage;
      data = ./electerm_deps.json;
      silent = false;
      useBwrap = false;
    };

    passthru = {
      inherit electermWebSrc nodeModules androidNodeModules;
      updateDeps = [
        "electermWebSrc"
        "nodeModules"
        "androidNodeModules"
      ];
      updateScript = writeShellScriptBin "update-electerm" ''
        set -euo pipefail
        package_file="app/apks/electerm/package.nix"
        package_attr=".#apk_electerm"
        fake_hash="${lib.fakeHash}"

        . "${../_shared/update-script-helpers.sh}"

        ${lib.getExe nix-update} --flake --src-only apk_electerm

        # electerm-web is not pinned upstream, so follow its default branch
        # together with the app and let the helper recompute the source hash.
        web_rev="$(
          ${lib.getExe git} ls-remote https://github.com/electerm/electerm-web.git refs/heads/main \
            | cut -f1
        )"
        [[ -n "$web_rev" ]] || { echo "error: could not resolve electerm-web main" >&2; exit 1; }
        old_rev="$(sed -n 's/^[[:space:]]*rev = "\([0-9a-f]*\)";$/\1/p' "$package_file" | head -n 1)"
        replace_literal "rev = \"$old_rev\";" "rev = \"$web_rev\";"

        refresh_update_deps ${lib.concatStringsSep " " finalAttrs.passthru.updateDeps}

        refresh_mitm_cache
      '';
    };

    nativeBuildInputs = [
      androidSdk
      gradle
      jdk21_headless
      nodejs_24
      writableTmpDirAsHomeHook
    ];

    env = {
      JAVA_HOME = jdk21_headless.passthru.home;
      ANDROID_HOME = androidHome;
      ANDROID_SDK_ROOT = androidHome;
      ANDROID_NDK_HOME = "${androidHome}/ndk/${ndkVersion}";
      # The aapt2 pulled from Maven at build time cannot start in the sandbox.
      ANDROID_AAPT2_FROM_MAVEN_OVERRIDE = aapt2Path;
    };

    # Everything up to the native project happens here, not in buildPhase, so
    # the Gradle dependency update script (configurePhase + gradleUpdateScript)
    # sees the same prepared tree.
    postPatch = ''
      cp -a ${nodeModules}/node_modules .
      cp -a ${androidNodeModules}/node_modules build/android/node_modules
      chmod -R u+w node_modules build/android/node_modules

        # Upstream's install.js would have fetched electerm-web here; apply the
        # same delta it applies: the overlay, the delete list, then the client
        # from the npm package, then the client-only overlay entries.
        rm -rf src
        cp -a ${electermWebSrc}/src src
        chmod -R u+w src
        overlay=build/replace/src
        apply_overlay() {
          local from="$1" to="$2"
          [ -d "$from" ] || return 0
          ( cd "$from" && find . -type f ) | while IFS= read -r rel; do
            install -Dm644 "$from/$rel" "$to/$rel"
          done
        }
        apply_overlay "$overlay" src
        while IFS= read -r rel; do
          rm -rf "''${rel#src/}"
        done < <(
          node --input-type=module -e \
            'import list from "./build/delete-list.js"; console.log(list.join("\n"))'
        )
        rm -rf src/client/electerm-react
        mkdir -p src/client/electerm-react
        cp -a node_modules/@electerm/electerm-react/client/. src/client/electerm-react/
        apply_overlay "$overlay/client/electerm-react" src/client/electerm-react
        node -p "require('./node_modules/@electerm/electerm-react/package.json').version" \
          > src/client/electerm-react/version

        # Frontend + Node.js backend bundle, then the native project. The
        # subshell keeps the working directory (gradle runs with -p).
        node build/android/build.mjs
        (
          cd build/android
          cap=node_modules/@capacitor/cli/bin/capacitor
          if [ ! -d android ]; then
            node "$cap" add android
          fi
          node "$cap" sync android

          # CI applies the icon/splash/MainActivity overlay after `cap sync`;
          # the template's own resources shadow parts of it and have to go.
          install -Dm644 res-overlay/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
          cp -r res-overlay/java/. android/app/src/main/java/
          cp -r res-overlay/. android/app/src/main/res/
          rm -rf android/app/src/main/res/java
          rm -f android/app/src/main/res/drawable-v24/ic_launcher_foreground.xml
          rm -f android/app/src/main/res/values/ic_launcher_background.xml
          find android/app/src/main/res -type f -name splash.png -path '*/drawable*' -delete

          node scripts/set-version.mjs android/app/build.gradle

          # Pin the NDK the Node.js plugin compiles against instead of letting
          # AGP download one, and point the plugin at the store copy of libnode.
          substituteInPlace android/app/build.gradle \
            --replace-fail \
              '    compileSdk = rootProject.ext.compileSdkVersion' \
              '    compileSdk = rootProject.ext.compileSdkVersion
        ndkVersion "${ndkVersion}"'
          printf '\next.nodejsMobileAndroidUrl = "file://%s"\n' "${nodejsMobileAndroid}" \
            >> android/variables.gradle
        )
    '';

    gradleFlags = [
      "-p"
      "build/android/android"
      "-PnodejsMobileAndroidUrl=file://${nodejsMobileAndroid}"
      "-Dorg.gradle.java.installations.auto-download=false"
      "-Dorg.gradle.java.installations.paths=${jdk21_headless.passthru.home}"
      "-Dandroid.aapt2FromMavenOverride=${aapt2Path}"
      "-Dorg.gradle.project.android.aapt2FromMavenOverride=${aapt2Path}"
    ];

    installPhase = ''
      runHook preInstall
      install -Dm644 \
        build/android/android/app/build/outputs/apk/release/app-release-unsigned.apk \
        "$out/electerm.apk"
      runHook postInstall
    '';

    meta = with lib; {
      sourceProvenance = with sourceTypes; [ fromSource ];
      description = "Terminal, SSH, SFTP, FTP, RDP, VNC and Spice client for Android";
      homepage = "https://electerm.org";
      license = licenses.mit;
      platforms = platforms.unix;
    };
  });
in
mk-apk-package {
  inherit appPackage;
  mainApk = "electerm.apk";
  signScriptName = "sign-electerm";
  fdroid = {
    appId = "org.electerm.electerm";
    metadataYml = ''
      Categories:
        - Internet
      License: MIT
      SourceCode: https://github.com/electerm/electerm-android
      IssueTracker: https://github.com/electerm/electerm-android/issues
      Changelog: https://github.com/electerm/electerm-android/releases
      AutoName: electerm
      Summary: Terminal, SSH/SFTP/FTP/RDP/VNC client
      Description: |-
        electerm is a terminal and remote-connection client for SSH, SFTP,
        FTP, Telnet, RDP, VNC and Spice.
        This package builds the upstream Android app from source: a Capacitor
        WebView frontend plus the electerm Node.js backend running on the
        device.
    '';
  };
}
