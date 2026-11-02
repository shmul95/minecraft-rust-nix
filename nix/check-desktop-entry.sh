#!/usr/bin/env bash
# Verifies RUN-03: the Nix-shipped static .desktop entry + icon set is correct,
# AND that Horizon's own self-written desktop entry (written silently on a bare
# GUI launch, with no opt-out) never reaches the real, on-disk
# $HOME/.local/share/applications of an actual user profile.
#
# RUN-03: closes the CR-01 -> T-01-03 -> T-02-04 lineage: 03-01's `$HOME`
#         narrowing (--tmpfs $HOME + explicit rebind of only .minecraft and
#         .local/share/horizon-launcher) already structurally prevents the
#         self-write from reaching a real $HOME/.local/share/applications,
#         since that path is intentionally left unbound. This script proves
#         it empirically against the final Task-1-narrowed derivation rather
#         than assuming the 03-01 finding still holds.
#
# Usage: nix/check-desktop-entry.sh
set -uo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# No cleanup trap: TESTHOME intentionally persists after exit so it remains
# inspectable for post-hoc debugging — this is a diagnostic script, not a
# cleanup-sensitive one. /tmp is reclaimed by the OS/tmpfs lifecycle anyway.

STATIC_OK=1

echo "# Building $FLAKE_DIR#default..." >&2
OUT="$(nix build "$FLAKE_DIR#default" --no-link --print-out-paths)"
if [ -z "$OUT" ] || [ ! -d "$OUT" ]; then
  echo "ERROR: nix build did not produce an output path — aborting rather than reporting a false result." >&2
  exit 1
fi
echo "# Output: $OUT" >&2

DESKTOP_FILE="$OUT/share/applications/horizon-launcher.desktop"
if [ -f "$DESKTOP_FILE" ] \
  && grep -q '^Exec=horizon-launcher$' "$DESKTOP_FILE" \
  && grep -q '^Icon=horizon$' "$DESKTOP_FILE"; then
  echo "# Static desktop entry found with correct Exec=/Icon= content." >&2
else
  echo "# Static desktop entry missing or malformed at $DESKTOP_FILE" >&2
  STATIC_OK=0
fi

ICON_COUNT=0
for size in 16x16 24x24 32x32 48x48 64x64 128x128 256x256 512x512; do
  if [ -f "$OUT/share/icons/hicolor/$size/apps/horizon.png" ]; then
    ICON_COUNT=$((ICON_COUNT + 1))
  fi
done
if [ -f "$OUT/share/icons/hicolor/scalable/apps/horizon.svg" ]; then
  ICON_COUNT=$((ICON_COUNT + 1))
fi
echo "# Icon files found: $ICON_COUNT/9" >&2
if [ "$ICON_COUNT" -ne 9 ]; then
  STATIC_OK=0
fi

if [ "$STATIC_OK" -eq 1 ]; then
  echo "RESULT: STATIC_ENTRY=PASS"
else
  echo "RESULT: STATIC_ENTRY=FAIL"
fi

# --- Part 2: confirm the self-written desktop entry never leaks into the
# real, on-disk $HOME/.local/share/applications of a totally fresh profile.
TESTHOME="$(mktemp -d)"
echo "# Fresh TESTHOME (never pre-populated): $TESTHOME" >&2

echo "# Running: HOME=$TESTHOME $OUT/bin/horizon-launcher (bare GUI launch, virtual display, bounded 8s timeout)" >&2
HOME="$TESTHOME" nix shell nixpkgs#xvfb-run --command \
  xvfb-run -a timeout 8s "$OUT/bin/horizon-launcher" \
  > "$TESTHOME/.run.log" 2>&1
RUN_EXIT=$?
echo "# Exit code: $RUN_EXIT" >&2

REAL_APPS_DIR="$TESTHOME/.local/share/applications"
NO_COLLISION_OK=1
if [ -d "$REAL_APPS_DIR" ]; then
  LEAKED_DESKTOP_FILES="$(find "$REAL_APPS_DIR" -maxdepth 1 -name '*.desktop' 2>/dev/null || true)"
  if [ -n "$LEAKED_DESKTOP_FILES" ]; then
    echo "# Real on-disk $REAL_APPS_DIR contains .desktop files (leak):" >&2
    echo "$LEAKED_DESKTOP_FILES" >&2
    NO_COLLISION_OK=0
  else
    echo "# Real on-disk $REAL_APPS_DIR exists but is empty of .desktop files." >&2
  fi
else
  echo "# Real on-disk $REAL_APPS_DIR does not exist at all (expected — self-write never left the sandbox's ephemeral tmpfs)." >&2
fi

if [ "$NO_COLLISION_OK" -eq 1 ]; then
  echo "RESULT: NO_COLLISION=PASS"
else
  echo "RESULT: NO_COLLISION=FAIL"
fi

if [ "$STATIC_OK" -eq 1 ] && [ "$NO_COLLISION_OK" -eq 1 ]; then
  echo "RESULT: RUN03_OVERALL=PASS"
  exit 0
else
  echo "RESULT: RUN03_OVERALL=FAIL"
  exit 1
fi
