#!/usr/bin/env bash
# Verifies that outbound HTTPS/TLS to Microsoft's OAuth device-code endpoint
# still works cleanly through the narrowed sandbox (nix/horizon-launcher.nix,
# Task 1 of 03-01-PLAN.md), reaching the point where the launcher prints a
# real device code + microsoft.com/link instruction.
#
# RUN-02: this script proves the MECHANISM — reachability, cert trust, the
#         launcher printing a real device code — not a completed sign-in.
#         It explicitly does NOT and cannot complete a real Microsoft sign-in:
#         no credentials are available to this environment, and completing
#         the actual interactive login remains a genuine, un-fabricated human
#         action outside this phase's automation boundary (per PROJECT.md's
#         honesty policy on checkpoints). The process below is killed by
#         `timeout` before any human could complete the flow even if present.
#
# Usage: nix/check-oauth-reachability.sh
set -uo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
# No cleanup trap: WORKDIR intentionally persists after exit so RUNLOG
# (printed below) remains readable for post-hoc inspection — this is a
# diagnostic script, not a cleanup-sensitive one. /tmp is reclaimed by the
# OS/tmpfs lifecycle anyway.
RUNLOG="$WORKDIR/run.log"
TESTHOME="$(mktemp -d)"

BIN_PATH="$(nix build "$FLAKE_DIR#default" --no-link --print-out-paths)/bin/horizon-launcher"
if [ ! -x "$BIN_PATH" ]; then
  echo "ERROR: nix build did not produce an executable at $BIN_PATH — aborting rather than reporting a false result." >&2
  exit 1
fi
echo "# Binary: $BIN_PATH" >&2
echo "# Work dir: $WORKDIR" >&2
echo "# Fresh HOME (never a real user profile): $TESTHOME" >&2

echo "# Running: HOME=$TESTHOME $BIN_PATH account sign-in (virtual display, bounded 20s timeout)" >&2
HOME="$TESTHOME" nix shell nixpkgs#xvfb-run --command \
  xvfb-run -a timeout 20s "$BIN_PATH" account sign-in \
  > "$RUNLOG" 2>&1
RUN_EXIT=$?
echo "# Exit code: $RUN_EXIT" >&2

DEVICE_CODE_LINE="$(grep -oE 'open https://www\.microsoft\.com/link.* enter the code [A-Za-z0-9]+' "$RUNLOG" || true)"
if [ -n "$DEVICE_CODE_LINE" ]; then
  echo "RESULT: DEVICE_CODE_PRINTED=PASS"
  echo "RESULT: DEVICE_CODE_LINE=$DEVICE_CODE_LINE"
  DEVICE_CODE_OK=1
else
  echo "RESULT: DEVICE_CODE_PRINTED=FAIL"
  echo "# Full run log follows (DEVICE_CODE_PRINTED=FAIL diagnosis):" >&2
  cat "$RUNLOG" >&2
  DEVICE_CODE_OK=0
fi

if grep -qiE 'certificate|cert error|unable to get local issuer|SSL error|handshake failure|UnknownIssuer|invalid certificate' "$RUNLOG"; then
  echo "RESULT: CERT_ERROR=FAIL"
  CERT_OK=0
else
  echo "RESULT: CERT_ERROR=NONE"
  CERT_OK=1
fi

echo "RESULT: RUN_LOG=$RUNLOG"
echo "RESULT: EXIT_CODE=$RUN_EXIT"

# NOTE: this script intentionally stops at the device-code print. It never
# provides credentials, never opens a real interactive browser session to
# complete sign-in, and the launcher process is killed by `timeout` before
# any human could finish the flow even if one were present. This is not a
# gap to fix — it is the correct, honest boundary of what this sandboxed,
# credential-less environment can automate per RUN-02's scope. Completing an
# actual Microsoft sign-in remains a genuine human action outside this
# script's (and this phase's) automation boundary.

if [ "$DEVICE_CODE_OK" -eq 1 ] && [ "$CERT_OK" -eq 1 ]; then
  echo "RESULT: RUN02_OVERALL=PASS"
  exit 0
else
  echo "RESULT: RUN02_OVERALL=FAIL"
  exit 1
fi
