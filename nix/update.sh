#!/usr/bin/env bash
# Bumps the pinned Horizon launcher release in nix/sources.json.
#
# Usage: nix/update.sh <new-version>
#   e.g. nix/update.sh 0.2.33
#
# This is the ONLY script that should touch nix/sources.json. After running
# it, review the diff, then `nix build .#default` to confirm the new pin
# resolves and builds.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <new-version>" >&2
  exit 1
fi

NEW_VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_JSON="$SCRIPT_DIR/sources.json"

# Horizon's GitHub release tag format is "launcher@<version>", URL-encoded as
# "launcher%40<version>" in the release asset download path.
URL="https://github.com/horizon-rust/horizon/releases/download/launcher%40${NEW_VERSION}/horizon-launcher-linux-x86_64.AppImage"

echo "Prefetching $URL ..." >&2
HASH="$(nix store prefetch-file --json "$URL" | jq -r '.hash')"

if [ -z "$HASH" ] || [ "$HASH" = "null" ]; then
  echo "Failed to compute hash for $URL — check the URL/tag is correct." >&2
  exit 1
fi

TMP_JSON="$(mktemp)"
jq -n --arg version "$NEW_VERSION" --arg url "$URL" --arg hash "$HASH" \
  '{version: $version, url: $url, hash: $hash}' > "$TMP_JSON"
mv "$TMP_JSON" "$SOURCES_JSON"

echo "Updated nix/sources.json:" >&2
cat "$SOURCES_JSON" >&2
echo "Now run: nix build .#default" >&2
