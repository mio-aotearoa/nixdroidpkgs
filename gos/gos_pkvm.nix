{ config, lib, ... }:
{
  options.enableUnprotectedKvm = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Build the device kernel with kvm-arm.mode=nvhe for Limbo/DroidVM KVM
      guests. This reduces pKVM isolation and requires a compatible device.
      Bundled Limbo/DroidVM use dedicated SELinux domains for /dev/kvm and do
      not need root. See docs/pkvm.md before enabling.
    '';
  };
}
