#!/usr/bin/env bash
# Release smoke test on a running emulator: install the R8-minified release
# APK, launch it, and require the app to report a successful startup.
#
# Debug builds skip R8, so a class that native code reaches over JNI and R8
# strips (e.g. the protected store's androidx.security.crypto classes) only
# breaks the release build. The integration test runs a debug build; this
# catches that gap.
#
#   release_smoke.sh <apk> <out-dir>
set -euo pipefail

APK="$1"
OUT="$2"
PKG=com.p2pcommunicator.p2p_communicator
mkdir -p "$OUT"

adb uninstall "$PKG" >/dev/null 2>&1 || true
adb install -r "$APK"
adb logcat -c
adb shell am start -W -n "$PKG/.MainActivity"

result=""
for _ in $(seq 1 60); do
  log=$(adb logcat -d -s flutter:I)
  if grep -q '\[startup\] ready' <<<"$log"; then result=ready; break; fi
  if grep -q '\[startup\] failed' <<<"$log"; then result=failed; break; fi
  sleep 2
done

sleep 3
adb exec-out screencap -p > "$OUT/release_smoke.png" || true
adb logcat -d > "$OUT/release_logcat.txt" || true
grep '\[startup\]' "$OUT/release_logcat.txt" || true

case "$result" in
  ready)
    echo "Release build started OK."
    ;;
  failed)
    echo "Release build failed to start (see release_smoke.png / release_logcat.txt)." >&2
    exit 1
    ;;
  *)
    echo "Release build did not report startup within 120 s." >&2
    exit 1
    ;;
esac

# Crash after startup also counts.
if grep -E "Process: $PKG|Fatal signal.*p2pcommunicator" "$OUT/release_logcat.txt"; then
  echo "Release build crashed." >&2
  exit 1
fi
