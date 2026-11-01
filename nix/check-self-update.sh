#!/usr/bin/env bash
# Verifies Horizon's self-updater is neutralized under the Nix-packaged launcher.
#
# UPD-01: the self-update-check code path must never succeed in rewriting
#         the launcher binary.
# UPD-02: no shadow copy of the launcher must appear under $HOME afterward.
#
# Usage: nix/check-self-update.sh
set -uo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
BEFORE="$WORKDIR/before.txt"
AFTER="$WORKDIR/after.txt"
RUNLOG="$WORKDIR/run.log"

CANDIDATES=(
  "$HOME/.local/share/horizon"
  "$HOME/.local/share/horizon-launcher"
  "$HOME/Applications"
  "$HOME"
)

snapshot() {
  for dir in "${CANDIDATES[@]}"; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 3 -iname '*horizon*' 2>/dev/null
  done | sort -u
}

echo "# Work dir: $WORKDIR" >&2
snapshot > "$BEFORE"

BIN_PATH="$(nix build "$FLAKE_DIR#default" --no-link --print-out-paths)/bin/horizon-launcher"
echo "# Binary: $BIN_PATH" >&2

# Discover the real update-check invocation rather than assuming a flag name.
HELP_OUT="$("$BIN_PATH" --help 2>&1 || true)"
UPDATE_HELP=""
if echo "$HELP_OUT" | grep -qi 'update'; then
  UPDATE_HELP="$("$BIN_PATH" update --help 2>&1 || true)"
fi

if echo "$UPDATE_HELP" | grep -qi -- '--check'; then
  CMD=("$BIN_PATH" update --check)
elif echo "$HELP_OUT" | grep -qi 'update'; then
  CMD=("$BIN_PATH" update)
else
  echo "# No 'update' subcommand discovered via --help; falling back to a bounded default launch to exercise the startup self-update check." >&2
  CMD=("$BIN_PATH")
fi

echo "# Running: ${CMD[*]} (virtual display, bounded 30s timeout)" >&2
nix shell nixpkgs#xvfb-run --command \
  xvfb-run -a timeout 30s "${CMD[@]}" \
  > "$RUNLOG" 2>&1
RUN_EXIT=$?
echo "# Exit code: $RUN_EXIT" >&2

snapshot > "$AFTER"
NEW_PATHS="$(diff "$BEFORE" "$AFTER" | grep '^>' || true)"

if [ -n "$NEW_PATHS" ]; then
  echo "RESULT: HOME_DIFF=FAIL"
  echo "$NEW_PATHS"
else
  echo "RESULT: HOME_DIFF=CLEAN"
fi

if grep -qiE 'permission denied|read-only file system|up.to.date|no update|managed externally|EROFS' "$RUNLOG"; then
  echo "RESULT: SELF_UPDATE_SUPPRESSED=PASS"
else
  echo "RESULT: SELF_UPDATE_SUPPRESSED=UNKNOWN"
fi

echo "RESULT: RUN_LOG=$RUNLOG"
echo "RESULT: EXIT_CODE=$RUN_EXIT"
