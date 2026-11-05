#!/usr/bin/env bash
# Quick task 261105-o0f: proves the four things the launcher's in-app "Native
# build of Horizon" pre-flight check enumerates — a C compiler (cc), pkg-config,
# ALSA development files, and libudev development files — all resolve inside the
# packaged launcher's FHS sandbox, via the native-build-deps-check probe app.
#
# Usage: nix/check-native-build-deps.sh
set -uo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# No cleanup trap: this script creates no state — it only runs a read-only probe.

OVERALL_PASS=1

out="$(nix run "$FLAKE_DIR#native-build-deps-check" 2>&1)"
run_status=$?

while IFS= read -r line; do
  echo "# $line" >&2
done <<< "$out"

if [ "$run_status" -ne 0 ]; then
  OVERALL_PASS=0
fi

if echo "$out" | grep -q '=FAIL'; then
  OVERALL_PASS=0
fi

if ! echo "$out" | grep -q 'RESULT: NATIVE_BUILD_DEPS_OVERALL=PASS'; then
  OVERALL_PASS=0
fi

if [ "$OVERALL_PASS" -eq 1 ]; then
  echo "RESULT: NATIVE_BUILD_DEPS_OVERALL=PASS"
  exit 0
else
  echo "RESULT: NATIVE_BUILD_DEPS_OVERALL=FAIL"
  exit 1
fi
