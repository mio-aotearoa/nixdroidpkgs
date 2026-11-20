# Pixel 9 Pro XL (komodo): Pixel 8 Pro-style PWM & DPP matrix experiment

## Background & why we switched back from the 1-byte experiment

- Commit `3320ffac` originally ported the Pixel 8 Pro (HK3) style 4-byte `freq_cmd` (`{mode, 0x43, 0x43, 0x03}` + `0x21` prefix) and `ea_panel_calc_backlight()` / `linear_matrix_application_threshold` DPP linear matrix scaling to CM4/KM4 (`kernel/pixel9pro-stock-0x01.patch`).
- Commit `2d0c67b6` replaced that with a minimal 1-byte `pwm_mode` experiment on register `0xBD` (without `43 43 03`, `0x21`, or DPP matrix compensation). On-device testing showed that all modes looked identical to stock and had no visible effect.
- This revision restores the `3320ffac` kernel patch (4-byte `freq_cmd` + DPP linear matrix override) so we can evaluate its behavior towards a working high-PWM hack on Pixel 9 Pro XL, while keeping the safer non-persistent boot-reset mechanism from `2d0c67b6`.

## Safe boot-reset behavior (always starts stock)

Every reboot is guaranteed to start in stock behavior:

1. **Kernel defaults are stock:**
   - `freq_cmd` defaults to `{0x00, 0x00, 0x00, 0x00}` in `panel-gs-km4.c` and `panel-gs-cm4.c`. Because `freq_cmd[1] == 0 && freq_cmd[2] == 0`, the driver takes the stock `0xB0 0x00 0x01 0xBD` / `0xBD val` path.
   - `linear_matrix_application_threshold` defaults to `1` in `exynos_drm_crtc.c` (disabled for all normal brightness levels).
2. **RAM-only Android property:**
   - Settings writes `sys.komodo_high_emission_frequency_mode` (non-persistent `sys.*` property, not `persist.sys.*`), so no selection can survive a reboot.
3. **Explicit `early-boot` reset & `boot_completed` guard:**
   - `init.komodo.pwm.rc` resets `sys.komodo_high_emission_frequency_mode` to `off`, `freq_cmd` to `0x00,0x00,0x00,0x00`, and `linear_matrix_application_threshold` to `1` on `early-boot`.
   - All mode triggers (`off`, `zero`..`seven`) require `property:sys.boot_completed=1`.

## What each mode sets

| UI selection | `freq_cmd` (`panel_gs_km4` / `panel_gs_cm4`) | `linear_matrix_application_threshold` (`exynos_drm`) |
| --- | --- | --- |
| `Off (stock; default each boot)` | `0x00,0x00,0x00,0x00` (stock path) | `1` (disabled) |
| `Mode 0` – `Mode 7` | `0x00..0x07,0x43,0x43,0x03` (plus `0x21` prefixed command) | `600` |

## Testing & observation checklist

1. **Baseline (`Off`):** Verify stock behavior, then select **Mode 0** (or another mode) in *Settings → Accessibility → Experimental PWM mode (resets after restart)*.
2. **Cycle screen off/on:** `km4_set_panel_feat_early_exit` / `cm4_set_panel_feat_early_exit` only sends `0xBD` commands on panel feature updates (e.g., screen off/on or refresh rate change).
3. **Observe brightness & DPP matrix scaling:**
   - When `linear_matrix_application_threshold` is `600` and requested brightness is `< 600`, `ea_panel_calc_backlight()` clamps panel hardware brightness to `600` and sets `linear_matrix_override` to scale down via DQE/DPP.
   - Note that `exynos_drm_crtc_get_linear_matrix()` is hooked in `exynos_drm_crtc_atomic_enable()`, so if the screen jumps bright on low brightness, test whether a screen off/on cycle or display commit engages the DPP matrix, or whether the DQE linear matrix scale/offset behavior differs on Pixel 9 (`caimito`/`zumapro`).
4. **Measure PWM:** Compare PWM frequency/duty cycle across modes `0`–`7` at fixed brightness (< 600 and >= 600) and refresh rates (60/80/120 Hz), plus AOD and fingerprint unlock.
5. **Verify reboot safety:** Reboot after selecting a non-Off mode and confirm `getprop sys.komodo_high_emission_frequency_mode` is `off`, `freq_cmd` is `0,0,0,0`, and `linear_matrix_application_threshold` is `1`.

## References

- [Original Pixel 8 Pro PWM/pixel-on-ratio change (updateing)](https://github.com/updateing/android_kernel_google_zuma/commit/759e096a6ba39687e0ebe20cf5845ecf69632868)
- [Kernel patch](file:///home/dev/Documents/repo2/kernel/pixel9pro-stock-0x01.patch)
- [Init RC patch](file:///home/dev/Documents/repo2/gos/komodo-high-emission-frequency-adevtool.patch)
- [Settings patch](file:///home/dev/Documents/repo2/gos/komodo-high-emission-frequency-settings.patch)
- [Sepolicy patch](file:///home/dev/Documents/repo2/gos/komodo-high-emission-frequency-sepolicy.patch)
