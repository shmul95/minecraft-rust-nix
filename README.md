# Horizon Nix Package

A Nix flake that packages the [Horizon launcher](https://github.com/horizon-rust/horizon) — a from-scratch Rust reimplementation of Minecraft: Java Edition — for NixOS/Nix. It pulls the official prebuilt Linux AppImage launcher, wraps it with its native runtime dependencies resolved, and exposes a runnable `horizon-launcher` package/app so you can play without hand-managing a loose AppImage.

## Usage

### Run it

```
nix run .#default
```

(equivalently `nix run .#horizon-launcher`) launches the packaged Horizon launcher directly.

### Build it

```
nix build .#default
```

builds the package, producing a `result` symlink into the Nix store.

### Maintainer dev shell

```
nix develop
```

drops you into a shell with `jq`, `curl`, `patchelf`, and `shellcheck` on `PATH` — everything the maintainer scripts below need. `nix fmt` formats the flake via `nixfmt-rfc-style`.

## Legal Prerequisite

You must already own a legitimate Minecraft Java Edition account/copy (26.3). This flake packages tooling only — it never bundles or redistributes Mojang-owned game assets. That claim isn't just asserted: `checks.${system}.no-mojang-assets-in-closure` statically confirms, at build time, that no Mojang/Minecraft-named store paths exist in the built closure.

## Signing In (Microsoft OAuth Device Code)

Horizon authenticates via Microsoft's OAuth device-code flow: on sign-in, the launcher prints a short code and a `https://www.microsoft.com/link` instruction. You open that URL in any browser (on this machine or another device) and enter the code there — there is no embedded webview in the launcher itself.

`nix/check-oauth-reachability.sh` verifies the *mechanism* (a real device code prints, reachability and TLS/cert trust to Microsoft's endpoint both check out) — it explicitly does not and cannot complete a real sign-in, since no credentials are available to automation. If you're curious about how Horizon stores the resulting credential/token afterward, consult upstream Horizon's own documentation — that mechanism isn't verified anywhere in this repo and this README doesn't guess at it.

## Version Bump Procedure

`nix/update.sh <new-version>` is the ONLY command that should touch `nix/sources.json` — it prefetches the new release asset's hash and rewrites the version/url/hash triple there in one shot.

```
nix/update.sh 0.2.33
```

After running it:

1. Review the diff to `nix/sources.json`.
2. Run `nix build .#default` to confirm the new pin resolves and builds.
