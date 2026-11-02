#!/usr/bin/env bash
# Verifies the CR-01 sandbox narrowing (nix/horizon-launcher.nix) still correctly
# passes through ~/.minecraft / HORIZON_MINECRAFT_DIR while hiding everything
# else under $HOME from the sandboxed launcher process.
#
# RUN-01: a fake/real ~/.minecraft (or HORIZON_MINECRAFT_DIR override) must be
#         read and written correctly by the packaged launcher running inside
#         the narrowed FHS sandbox, while content outside the narrowed bind
#         paths (e.g. an unrelated file directly in $HOME) stays invisible.
#
# Usage: nix/check-home-passthrough.sh
set -uo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# No cleanup trap: test workdirs intentionally persist after exit so they
# remain inspectable for post-hoc debugging — this is a diagnostic script,
# not a cleanup-sensitive one. /tmp is reclaimed by the OS/tmpfs lifecycle.

OVERALL_PASS=1

run_scenario() {
  local label="$1"
  local testhome="$2"
  local mc_override="${3:-}"

  echo "# Scenario: $label (HOME=$testhome${mc_override:+, HORIZON_MINECRAFT_DIR=$mc_override})" >&2

  local out
  if [ -n "$mc_override" ]; then
    out="$(HOME="$testhome" HORIZON_MINECRAFT_DIR="$mc_override" nix run "$FLAKE_DIR#home-passthrough-check" 2>&1)"
  else
    out="$(HOME="$testhome" nix run "$FLAKE_DIR#home-passthrough-check" 2>&1)"
  fi

  echo "$out" | sed "s/^/# [$label] /" >&2

  local mc_dir leak write
  mc_dir="$(echo "$out" | grep -oE 'RESULT: MC_DIR=.*' | head -1)"
  leak="$(echo "$out" | grep -oE 'RESULT: LEAK_TEST=(PASS|FAIL)' | head -1)"
  write="$(echo "$out" | grep -oE 'RESULT: WRITE_TEST=PASS' | head -1)"

  echo "RESULT: ${label}_MC_DIR=${mc_dir#RESULT: MC_DIR=}"

  if [ "$leak" = "RESULT: LEAK_TEST=PASS" ]; then
    echo "RESULT: ${label}_LEAK_TEST=PASS"
  else
    echo "RESULT: ${label}_LEAK_TEST=FAIL"
    OVERALL_PASS=0
  fi

  if [ -n "$write" ]; then
    echo "RESULT: ${label}_WRITE_TEST=PASS"
  else
    echo "RESULT: ${label}_WRITE_TEST=FAIL"
    OVERALL_PASS=0
  fi

  if [ -n "$mc_override" ]; then
    if echo "$mc_dir" | grep -qF "$mc_override"; then
      echo "RESULT: ${label}_OVERRIDE_HONORED=PASS"
    else
      echo "RESULT: ${label}_OVERRIDE_HONORED=FAIL"
      OVERALL_PASS=0
    fi
  fi
}

# Scenario 1: pre-populated profile — a decoy secret directly in $HOME plus a
# pre-existing fake Minecraft world. Confirms the decoy is invisible inside
# the sandbox and the pre-existing world data round-trips a write.
TESTHOME="$(mktemp -d)"
echo "top-secret-should-not-be-visible" > "$TESTHOME/secret.txt"
mkdir -p "$TESTHOME/.minecraft/saves/TestWorld"
echo "fake-level-data" > "$TESTHOME/.minecraft/saves/TestWorld/level.dat"
echo "# TESTHOME: $TESTHOME" >&2

run_scenario "PREPOPULATED" "$TESTHOME"

# Scenario 2: truly fresh profile (no pre-existing .minecraft or
# launcher-state dir at all) with HORIZON_MINECRAFT_DIR pointed at a third,
# separate location that has its own fake world file. Confirms the override
# is honored and the from-scratch startup doesn't crash.
TESTHOME2="$(mktemp -d)"
MCDIR_OVERRIDE="$(mktemp -d)/minecraft-override"
mkdir -p "$MCDIR_OVERRIDE/saves/OverrideWorld"
echo "fake-override-level-data" > "$MCDIR_OVERRIDE/saves/OverrideWorld/level.dat"
echo "# TESTHOME2: $TESTHOME2 (no pre-existing .minecraft)" >&2
echo "# MCDIR_OVERRIDE: $MCDIR_OVERRIDE" >&2

run_scenario "FRESH_WITH_OVERRIDE" "$TESTHOME2" "$MCDIR_OVERRIDE"

if [ "$OVERALL_PASS" -eq 1 ]; then
  echo "RESULT: RUN01_OVERALL=PASS"
  exit 0
else
  echo "RESULT: RUN01_OVERALL=FAIL"
  exit 1
fi
