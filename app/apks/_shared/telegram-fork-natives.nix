# Native JNI libraries shared by the Telegram Android forks in
# app/apks/forkgram and app/apks/forkgram-classic: the tlottie and
# gram-wallet static libraries are built with the same cross Rust toolchain
# from each package's own source checkout.
#
# Usage:
#   natives = import ../_shared/telegram-fork-natives.nix {
#     inherit androidSdkBuilder path rustPlatform stdenv;
#   } { inherit version src; };
{
  androidSdkBuilder,
  path,
  rustPlatform,
  stdenv,
}:
{
  version,
  src,
}:
let
  androidSdk = androidSdkBuilder (s: [
    s.cmdline-tools-latest
    s.platform-tools
    s.platforms-android-36
    s.platforms-android-35
    s.build-tools-36-0-0
    s.build-tools-35-0-0
    s.ndk-27-2-12479018
  ]);

  androidCrossConfig = {
    config.allowUnfree = true;
    localSystem = stdenv.buildPlatform.system;
  };

  mkAndroidPkgs =
    {
      config,
      rustTarget,
    }:
    import path (
      androidCrossConfig
      // {
        crossSystem = {
          inherit config;
          androidSdkVersion = "35";
          androidNdkVersion = "29";
          useAndroidPrebuilt = true;
          rust.rustcTarget = rustTarget;
        };
      }
    );

  aarch64AndroidPkgs = mkAndroidPkgs {
    config = "aarch64-unknown-linux-android";
    rustTarget = "aarch64-linux-android";
  };

  armv7AndroidPkgs = mkAndroidPkgs {
    config = "armv7a-unknown-linux-androideabi";
    rustTarget = "armv7-linux-androideabi";
  };

  tlottieCargoDeps = rustPlatform.fetchCargoVendor {
    pname = "forkgram-tlottie";
    inherit version src;
    cargoRoot = "TMessagesProj/jni/tlottie";
    hash = "sha256-R/l5zMRB/2/a4Yf6toPBBvJ1SvebWsGeumwW9U6b7So=";
  };

  mkTlottieArchive =
    {
      abi,
      crossPkgs,
      rustTarget,
    }:
    crossPkgs.rustPlatform.buildRustPackage {
      pname = "forkgram-tlottie-${abi}";
      inherit version src;

      sourceRoot = "${src.name}/TMessagesProj/jni/tlottie";
      cargoDeps = tlottieCargoDeps;
      CARGO_BUILD_TARGET = rustTarget;
      doCheck = false;

      buildPhase = ''
        runHook preBuild
        cargo rustc \
          --profile release-nostd \
          --target ${rustTarget} \
          --lib \
          --no-default-features \
          --features cpu,no-std,c-api \
          --crate-type staticlib
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm644 target/${rustTarget}/release-nostd/libtlottie.a \
          "$out/${abi}/libtlottie.a"
        runHook postInstall
      '';
    };

  tlottieArm64 = mkTlottieArchive {
    abi = "arm64-v8a";
    crossPkgs = aarch64AndroidPkgs;
    rustTarget = "aarch64-linux-android";
  };

  tlottieArmv7 = mkTlottieArchive {
    abi = "armeabi-v7a";
    crossPkgs = armv7AndroidPkgs;
    rustTarget = "armv7-linux-androideabi";
  };

  walletCargoDeps = rustPlatform.fetchCargoVendor {
    pname = "forkgram-wallet";
    inherit version src;
    cargoRoot = "TMessagesProj/jni/gram-wallet";
    hash = "sha256-awT4+c2Woe2SrnXPKS9uhvDuyYlhxp6CZMdHpXBIAog=";
  };

  llvmObjcopy = "${androidSdk}/share/android-sdk/ndk/27.2.12479018/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-objcopy";

  mkWalletArchive =
    {
      abi,
      crossPkgs,
      rustTarget,
    }:
    crossPkgs.rustPlatform.buildRustPackage {
      pname = "forkgram-wallet-${abi}";
      inherit version src;

      sourceRoot = "${src.name}/TMessagesProj/jni/gram-wallet";
      cargoDeps = walletCargoDeps;
      CARGO_BUILD_TARGET = rustTarget;
      doCheck = false;

      buildPhase = ''
        runHook preBuild
        cargo rustc \
          --release \
          --target ${rustTarget} \
          --lib \
          --crate-type staticlib
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm644 target/${rustTarget}/release/libgram_wallet.a \
          "$out/${abi}/libwallet_engine.a"
        "${llvmObjcopy}" \
          --redefine-sym rust_eh_personality=wallet_engine_rust_eh_personality \
          --redefine-sym DW.ref.rust_eh_personality=DW.ref.wallet_engine_rust_eh_personality \
          "$out/${abi}/libwallet_engine.a"
        runHook postInstall
      '';
    };

  walletArm64 = mkWalletArchive {
    abi = "arm64-v8a";
    crossPkgs = aarch64AndroidPkgs;
    rustTarget = "aarch64-linux-android";
  };

  walletArmv7 = mkWalletArchive {
    abi = "armeabi-v7a";
    crossPkgs = armv7AndroidPkgs;
    rustTarget = "armv7-linux-androideabi";
  };
in
{
  inherit
    androidSdk
    tlottieArm64
    tlottieArmv7
    tlottieCargoDeps
    walletArm64
    walletArmv7
    walletCargoDeps
    ;
}
