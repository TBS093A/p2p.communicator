#!/usr/bin/env bash
# Fails unless every 64-bit native library in the given APK/AAB is aligned
# to 16 KB pages (Google Play requirement for Android 15+ devices).
#
#   check_16k.sh build/app/outputs/flutter-apk/app-github-release.apk
set -euo pipefail

archive="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mapfile -t entries < <(unzip -Z1 "$archive" | grep -E '(arm64-v8a|x86_64)/[^/]+\.so$' || true)
if [ "${#entries[@]}" -gt 0 ]; then
  unzip -q -o "$archive" "${entries[@]}" -d "$work"
fi
mapfile -t libs < <(find "$work" -name '*.so' \( -path '*arm64-v8a*' -o -path '*x86_64*' \) | sort)
if [ "${#libs[@]}" -eq 0 ]; then
  echo "no 64-bit native libraries found in $archive" >&2
  exit 1
fi

bad=0
for lib in "${libs[@]}"; do
  name="${lib#"$work"/}"
  # Every LOAD segment's alignment must be at least 2**14.
  aligns=$(readelf -lW "$lib" | awk '/LOAD/ {print $NF}' | sort -u | tr '\n' ' ')
  ok=1
  [ -n "$aligns" ] || ok=0
  for a in $aligns; do
    [ $((a)) -ge 16384 ] || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok: $name ($aligns)"
  else
    echo "NOT 16 KB aligned: $name (LOAD align $aligns)"
    bad=1
  fi
done
exit "$bad"
