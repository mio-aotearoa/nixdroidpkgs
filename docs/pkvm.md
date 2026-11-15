# Unprotected KVM on Pixel devices

The optional `enableUnprotectedKvm` GrapheneOS setting builds the custom kernel
with `kvm-arm.mode=nvhe`. This allows KVM guests to use memory features blocked
by protected KVM, including the writable pflash needed by Limbo's full UEFI
mode. It reduces pKVM isolation.

The alternative in the [Limbo pKVM guide](https://github.com/wasdwasd0105/limbo_tensor/blob/master/docs/unlock-pkvm.md)
is to use the bootloader: run `fastboot oem pkvm enable`, then
`fastboot oem cmdline add kvm-arm.mode=nvhe`, and check with
`fastboot oem cmdline show`. Remove it with
`fastboot oem cmdline del kvm-arm.mode=nvhe`.

When `bundleLimboTensor` or `bundleDroidVM` is enabled, GrapheneOS gets a
dedicated SELinux domain for each app (`limbo_tensor_app` / `droidvm_app`) that
can open `/dev/kvm`. The bundled APKs are patched to run their QEMU/helpers as
the app UID instead of through `su`, so those emulators do not need root.
DroidVM additionally needs a supported backend exposed by the device
(`/dev/kvm`, `/dev/gunyah`, or `/dev/gzvm`). The bootloader method and this
kernel option only change KVM mode; they do not grant app root access.

For Pixel 8 devices, the upstream guide warns that the bootloader command-line
method requires Android 14 QPR3 or newer to preserve USB functionality.
