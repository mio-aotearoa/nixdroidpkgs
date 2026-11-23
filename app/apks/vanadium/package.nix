{
  mk-apk-package,
  sources,
  lib,
  stdenvNoCC,
}:

let
  appPackage = stdenvNoCC.mkDerivation {
    pname = "vanadium-browser";
    version = sources.grapheneos_vanadium.date;
    src = sources.grapheneos_vanadium.src;
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      install -Dm644 $src/prebuilt/arm64/VanadiumBrowser.apk $out/VanadiumBrowser.apk
      runHook postInstall
    '';

    meta = {
      description = "Privacy and security focused Chromium-based browser from GrapheneOS";
      homepage = "https://github.com/GrapheneOS/Vanadium";
      license = lib.licenses.bsd3;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = lib.platforms.unix;
    };
  };
in
mk-apk-package {
  inherit appPackage;
  mainApk = "VanadiumBrowser.apk";
  signScriptName = "sign-vanadium";
  fdroid = {
    appId = "app.vanadium.browser";
    preSigned = true;
    metadataYml = ''
      Categories:
        - System
      License: BSD-3-Clause
      SourceCode: https://github.com/GrapheneOS/Vanadium
      AutoName: Vanadium
      Summary: Privacy and security focused Chromium-based browser
      Description: |-
        Vanadium is a privacy and security focused Chromium-based browser
        developed by GrapheneOS.
    '';
  };
}
