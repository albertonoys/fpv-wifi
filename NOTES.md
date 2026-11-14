# kepyur dev notes

## Session 2026-11-14 — Android stalls, USB throughput, submodules on forks

### Hardware under test
- **Huawei MediaPad M5 Lite 10** (BAH2-W19), Android 8.0.0 — adb `192.168.10.114:5555`.
  USB-C port is **USB 2 only** (confirmed: adapter pins at 5 MS/s).
- **Samsung Galaxy S23** (SM-S911B), USB 3 — adb (wireless debug)
  `adb-RFCW40KB5CM-YL9eWp._adb-tls-connect._tcp` (now the `ANDROID_SERIAL` default in the justfile).
- **Adapter:** RTL8822BU = TP-Link Archer **T3U Plus** (`2357:0138`), used as an SDR for analog FPV video.

### What was done
1. **Launch crash on Android 8** — `getInsetsController()` is API 30; crashed on API 26.
   `hideSystemBars()` now version-gates and falls back to `systemUiVisibility`. Fixed.
2. **skip-USB3 option** — `skipUsb3` is **in-memory, re-probed each launch** (not persisted):
   the RTL8822BU boots USB 2 and only becomes USB 3 after the switch, so a sticky skip would pin a
   USB-3 phone at USB 2. A USB-2-only host (tablet) re-churns once per launch.
3. **usbtest runs at USB 2** — native clamps the test rate to `min_rate_sel` (5 MS/s on USB 2);
   Kotlin guard `mode != "usbtest"` lets the test proceed past the USB2 state.
4. **Settle delay + rate fallback** — 1 s settle after the link comes up; on repeated stream failure the
   usbtest records the rate failed and drops to the next instead of wedging.
5. **stopTest** clears the on-screen progress **and** the 3 reopen strikes (`testResults`/`reopens`).
6. **Build + justfile** — `just build` = `nix-shell --run 'scripts/build-android.sh'` (uses `shell.nix`,
   not a flake; `flake.nix` was removed). Recipes: build/install/reinstall/run/usbtest/logcat/clear/log/
   results/devices/**power**. `ANDROID_SERIAL` is an exported justfile var (defaults to the S23).
7. **Reset-on-reopen** (the wedge fix, see below).
8. **Submodules repointed to personal forks** (see below).

### Test results (see logs/usb-test-results.md for tables)
| Host / link | 40 MS/s | 20 MS/s | 5 MS/s |
|---|---|---|---|
| Tablet, USB 2, powered hub | — | — | ~96–99%, but 4–15 stream restarts/min (flaky) |
| S23, USB 3, powered hub | 3.5%, 324 restarts/min (limps) | **flawless, 0 restarts** | — |
| S23, USB 3, UGREEN direct cable | wedges (0 banks) | wedges (0 banks) | — |
| S20 (SM-G981B), USB 3 | 99.8%, 0 gaps/drops (1 startup restart) | ~100%, 0 gaps/drops | — |

- **The S23 direct-cable wedge is host/cable-specific, not the adapter.** Same `2357:0138` on the S20
  (Android 13) negotiates USB 3 and runs both phases clean (`all done`). So the stream path and firmware
  are fine; the S23+UGREEN SuperSpeed link is the problem, and `libusb_reset_device` on reopen does not
  clear it (every reopen re-inits the chip but wedges with the identical `r294 01016068 r7c0 800000cb`).
  Next: on the S23 direct cable, force USB 2 (`--ez usb3 false`) and compare.

### Diagnosis of the S23 direct-cable failure
- Symptom: stream **arms but delivers zero bulk-IN packets** (`no packet within timeout (bank 0 part 0)`),
  **identical register state every reopen** (`r294 01016068 r7c0 800000cb`, state 1, seq 0).
- A **fresh physical replug** gets it streaming (saw 40 MS/s for ~12 s once); a **software reopen never
  recovers** — only re-enumeration clears it.
- **Power sampler (`just power`):** during the 12 s streaming burst ≈ **1.25 A / 4.7 W, battery sag 230 mV**;
  during the wedged failures only ≈ **232 mA** (nothing is streaming). So the wedge is **not power** — it is a
  **stuck SuperSpeed bulk endpoint**. The 12 s burst that *did* stream was power-limited, which is a separate
  thing; a powered hub both feeds and re-times SuperSpeed and gave flawless 20 MS/s.
- **Root cause:** `third_party/wifi-sdr/src/receiver.cpp` forced `OpenOpts::reset = false` on the Android fd
  path (a `libusb_reset_device` can re-enumerate and invalidate the granted fd). So every reopen re-claims the
  **same wedged chip state**. A replug re-enumerates and clears it; the software reopen can't.

### The fix (implemented, NOT yet verified on hardware)
- `RxSettings::usb_reset` (fork `wifi-sdr`): on the fd path, `o.reset` follows it instead of being forced
  false. First open stays reset-free (don't invalidate a fresh fd); a **reopen** sets it true.
- Plumbed: `Radio::open(fd, usb_reset)` → JNI `open(fd, usbReset)` → `Native.open(fd, usbReset)` →
  `MainActivity.connect(reset)`. The two in-place retries (stall reopen, usbtest next-phase) call
  `connect(reset = true)`; fresh connects stay reset-free.

### Submodules — now on personal forks
- **wifi-sdr** → `github.com/albertonoys/wifi-sdr`, branch **`android`**, pin `f368d36`.
  `android` = snokvist/main + 6 vetted commits (Android fd open, T3U/T3U Plus pids + model_pid infra,
  WebUSB bulk-IN, 8822B retune, 20 MS/s BW20 DFIR) + the reset-on-reopen commit. **Pushed to GitHub.**
  (gilankpam `kepyur-android` was just snokvist + those 6; the fork now hosts the same + the fix.)
- **libusb** → `github.com/albertonoys/libusb`, branch **`master`**, pin `d3937ff1` (v1.0.30 + 160).
  Required a glue fix: `native/cmake/libusb_android.cmake` now runs `build-aux/gen-describe.sh` to generate
  `version_describe.h` (libusb ≥ 1.0.30 includes it from core.c), include dir added, empty-macro fallback.
- devourer's `external/devourer/reference/*` submodules stay **uninitialized** — reference-only vendor
  driver trees, never compiled; only needed to re-run devourer's `tools/vendor_hal*.sh`.

### State at end of session
- **Build green** — `android/app/build/outputs/apk/debug/app-debug.apk` (~8.3 MB).
- Superproject **uncommitted**: native/radio, JNI, Native.kt, MainActivity, `native/cmake/libusb_android.cmake`,
  `android/app/build.gradle.kts`, `shell.nix`, both submodule bumps + `.gitmodules`, `flake.nix` removed,
  new `justfile`. Only push made all session: the `android` branch to the wifi-sdr fork (approved).

### Next steps
1. **Verify the wedge fix:** `just install` then `just usbtest` on the S23 with the **UGREEN direct cable**.
   Watch for whether a reopen now revives the stream without a physical replug.
   - Risk: on some OEM kernels `libusb_reset_device` on a wrapped fd re-enumerates and invalidates the fd →
     reopen fails (no worse than today's "replug"). If so, treat as detach / re-acquire.
2. Confirm **20 MS/s still flawless** on this build (regression check vs the libusb bump).
3. If 40 MS/s stays power-bound, make **normal/video mode prefer 20 MS/s** on the S23 (watch already falls
   back; scan still runs at 40).
4. **Watch the libusb bump** for any runtime behavior change (1.0.23-era → 1.0.30+160).
5. Commit the superproject once the fix is verified (submodule bumps, native, cmake, justfile, stopTest).
6. Open question (noted, unverified): reopen 3-strike cap interaction with the usbtest fallback — the 16:28
   log showed many reopens; confirm the per-rate cap behaves.
