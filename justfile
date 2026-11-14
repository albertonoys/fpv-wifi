# kepyur dev tasks — run `just` to list.
#
# adb target: every adb recipe resolves a device via `_pick`. With one device it is used
# automatically; with more than one you are prompted (gum/fzf) by alias (S20/S23). To skip
# the prompt, export ANDROID_SERIAL to a serial or an alias (`set -x ANDROID_SERIAL S23`) —
# but it is HONORED ONLY IF THAT DEVICE IS ATTACHED; a stale/disconnected value is ignored
# (with a warning) and you pick/auto from what is connected, so it never targets a ghost.
# A recipe that calls another (capture → log → usbtest) resolves once and passes the choice
# down, so you are asked at most once per run. `just devices` lists the serials.

# adb target — empty means "resolve per run via _pick"; export it to pin a device.
export ANDROID_SERIAL := env_var_or_default("ANDROID_SERIAL", "")

pkg := "com.kepyur.app"
activity := pkg + "/.MainActivity"
apk := "android/app/build/outputs/apk/debug/app-debug.apk"
logfile := "/storage/emulated/0/Android/data/" + pkg + "/files/kepyur.log"

_default:
    @just --list

# Resolve the adb target and echo its serial. Reuses ANDROID_SERIAL if a caller set it;
# else auto-picks a lone device; else prompts by alias (2+ devices). Add phones to the maps.
[private]
_pick:
    #!/usr/bin/env bash
    set -euo pipefail
    serial_of() { case "$1" in
      S23) echo adb-RFCW40KB5CM-YL9eWp._adb-tls-connect._tcp;;
      S20) echo adb-RFCN607HJKV-t62Wto._adb-tls-connect._tcp;;
      *)   echo "$1";; esac; }                        # unknown choice/preset == its own serial
    alias_of() { case "$1" in
      adb-RFCW40KB5CM-YL9eWp._adb-tls-connect._tcp) echo S23;;
      adb-RFCN607HJKV-t62Wto._adb-tls-connect._tcp) echo S20;;
      *) echo "$1";; esac; }
    serials=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
    # honor a preset ANDROID_SERIAL (serial or alias) only if that device is attached, else ignore it
    if [ -n "${ANDROID_SERIAL:-}" ]; then
      want="$(serial_of "$ANDROID_SERIAL")"
      if printf '%s\n' "$serials" | grep -qxF "$want"; then printf '%s\n' "$want"; exit 0; fi
      echo "ANDROID_SERIAL=$ANDROID_SERIAL not attached — ignoring it, choosing from connected devices" >&2
    fi
    n=$(printf '%s\n' "$serials" | grep -c .)
    [ "$n" -eq 0 ] && { echo "no adb device connected" >&2; exit 1; }
    [ "$n" -eq 1 ] && { printf '%s\n' "$serials"; exit 0; }
    menu=$(printf '%s\n' "$serials" | while read -r s; do alias_of "$s"; done)
    if   command -v gum >/dev/null; then sel=$(printf '%s\n' "$menu" | gum choose --header "which device?")
    elif command -v fzf >/dev/null; then sel=$(printf '%s\n' "$menu" | fzf --prompt "device> ")
    else echo "multiple devices — install gum or fzf, or export ANDROID_SERIAL" >&2; exit 1; fi
    [ -n "$sel" ] || { echo "no device chosen" >&2; exit 1; }
    serial_of "$sel"

# Build the debug APK (inside the nix shell; wraps scripts/build-android.sh)
build:
    nix-shell --run 'scripts/build-android.sh'

# Build, then reinstall over the existing app (keeps data)
install: build
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb install -r {{apk}}

# Reinstall the already-built APK without rebuilding
reinstall:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb install -r {{apk}}

# Launch the app normally (scan + watch)
run:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb shell am force-stop {{pkg}}
    adb shell am start -n {{activity}}

# Run the USB throughput test (both rate phases)
usbtest:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb shell am force-stop {{pkg}}
    adb shell am start -n {{activity}} --es mode usbtest

# Follow the app's own log lines live (tag filter — no SurfaceFlinger/system noise)
logcat:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb logcat -s kepyur:V

# Clear the logcat buffer — do this before a fresh capture (run/usbtest force-stop the app themselves)
clear:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb logcat -c

# Print the app's own persistent log file (survives logcat -c and reboots)
applog:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb shell 'cat {{logfile}}'

# Merge logcat + battery power into one live stream, saved to logs/logcat/<timestamp>[-label].log.
# label tags the file to tell runs apart; launch (run|usbtest) starts that recipe first, after the
# buffer clear so no startup lines are lost. One command per combination:
#   just log s23-hub-powered usbtest
log label="" launch="":
    #!/usr/bin/env bash
    set -euo pipefail
    export ANDROID_SERIAL="$(just _pick)"   # resolve once; passed down to launch
    # bounded wait so a transient drop (wireless adb dies in the USB inrush) fails fast with guidance, not a silent hang
    timeout 20 adb wait-for-device 2>/dev/null || { echo "device $ANDROID_SERIAL not ready — wireless adb likely dropped in the USB power storm; use a USB cable for adb on these tests" >&2; exit 1; }
    mkdir -p logs/logcat
    suffix=""
    [ -n "{{label}}" ] && suffix="-$(printf %s "{{label}}" | tr -c 'A-Za-z0-9._-' '-')"
    out="logs/logcat/$(date +%Y%m%d-%H%M%S)$suffix.log"
    full="${out%.log}.full.log"              # unfiltered logcat (all tags) — the kepyur filter may hide USB/kernel events
    adb logcat -c                            # clear the buffer so only this run's lines land
    [ -n "{{launch}}" ] && just {{launch}}   # now start the app so its startup is captured
    echo "logging logcat + power to $out (+ unfiltered $full)  ([enter]=mark unplug moment, type a note first optional · ctrl-c=stop)" >&2
    exec > >(tee "$out")          # everything below goes to the console and the file
    exec 4<&0                     # save stdin: a backgrounded reader otherwise gets /dev/null (no job control)
    # each enter on stdin drops a timestamped MARK into the stream (e.g. the instant you unplug)
    ( while IFS= read -r note <&4; do printf 'MARK %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${note:-disconnect}"; done ) & mk=$!
    # battery power samples ~2x/sec, independent of logcat so an adb blip can't end the capture
    # rows: "POWER <iso-ts> <current_mA> <voltage_mV>" — grep '^POWER', awk cols $2/$3/$4
    ( while :; do
        printf 'POWER %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" \
          "$(adb shell dumpsys battery 2>/dev/null | awk '/^  voltage:/{v=$NF} /current now:/{c=$NF} END{printf "%s %s", c, v}')"
        sleep 0.5
      done ) & pw=$!
    # full unfiltered logcat to its own file (not the console); reconnect like the main loop so an adb blip can't end it
    ( ffirst=1; while :; do
        if [ "$ffirst" = 1 ]; then adb logcat >> "$full" 2>&1 || true; else adb logcat -T 1 >> "$full" 2>&1 || true; fi
        ffirst=0; sleep 1
      done ) & fl=$!
    trap 'kill $mk $pw $fl 2>/dev/null' EXIT
    stop=0; trap 'stop=1' INT     # ctrl-c: finish the current logcat, then break the loop
    # follow logcat until ctrl-c; reconnect if adb drops it (USB inrush / enumeration can blip adb)
    first=1
    while [ "$stop" = 0 ]; do
      [ "$first" = 1 ] || printf 'LOGCAT %s reconnecting\n' "$(date +%Y-%m-%dT%H:%M:%S)"
      if [ "$first" = 1 ]; then adb logcat -s kepyur:V || true; else adb logcat -s kepyur:V -T 1 || true; fi
      first=0
      [ "$stop" = 0 ] && sleep 1 || true
    done

# One command per combination: pick the device (if >1), clear, launch the USB test, and log
# logcat+power to a labelled file. The device is resolved here and passed to log/usbtest.
#   just capture s23-hub-powered
capture label="":
    #!/usr/bin/env bash
    set -euo pipefail
    export ANDROID_SERIAL="$(just _pick)"
    exec just log "{{label}}" usbtest

# Just the test results from the app log
results:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    adb shell 'cat {{logfile}}' | grep -iE 'start,|USB (2|3)|stream test at|test: result|usbtest: all done'

# Sample battery current (mA, negative = discharge) & voltage (mV) ~2x/sec for 60 s.
# Run it while the adapter streams (replug and watch) to see the OTG draw and any voltage sag.
power:
    #!/usr/bin/env bash
    export ANDROID_SERIAL="$(just _pick)"
    echo "time      current_mA  voltage_mV"
    for i in $(seq 1 120); do
      printf '%s  ' "$(date +%H:%M:%S)"
      adb shell dumpsys battery 2>/dev/null | awk '/^  voltage:/{v=$NF} /current now:/{c=$NF} END{printf "%-10s %s\n", c, v}'
      sleep 0.5
    done

# List attached adb devices and their serials
devices:
    adb devices -l
