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

You must already own a legitimate Minecraft Java Edition account/copy (currently version 26.3). This flake packages tooling only — it never bundles or redistributes Mojang-owned game assets. That claim isn't just asserted: `checks.${system}.no-mojang-assets-in-closure` scans the built closure's store-path *names* for Mojang/Minecraft-style naming — a name-pattern heuristic, not a content/filename-inside-output scan, which is sufficient today since no phase of this project ever fetches real Minecraft assets at build time.

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

## Security Posture (Sandbox Narrowing)

`appimageTools.wrapType2`/`buildFHSEnv` (what this package is built on) is an FHS *compatibility* shim, not a security sandbox. By default, it bind-mounts every top-level host directory except `/nix /dev /proc /etc` read-write into the sandbox the untrusted, third-party AppImage runs in — including all of `/home`.

This package narrows that default (CR-01, resolved in Phase 3): it mounts a `tmpfs` over `$HOME` first (deny by default), then explicitly re-binds only the two paths Horizon actually needs — `~/.minecraft` (or `$HORIZON_MINECRAFT_DIR` if set) and `~/.local/share/horizon-launcher`. Everything else under your real `$HOME` is invisible to the sandboxed launcher process.

Documented residual scope (WR-04): this narrowing assumes `$HOME` is a direct child of `/home` (e.g. `/home/<user>`). Don't run this package as `root` (`$HOME=/root`) or with a custom `useradd -d` home outside `/home` — in that case the enclosing top-level directory falls back to the fully-exposed, unnarrowed default. Network access is never unshared for the real package, since both OAuth sign-in and Horizon's own update-check call need it.

Separately, Horizon's self-updater is neutralized via `HORIZON_LAUNCHER_NO_SELF_UPDATE=1` (set by this package's wrapper), independently verified by `nix/check-self-update.sh`.

## Maintainer Tooling & Verification Scripts

| Script | Purpose |
|---|---|
| `nix/update.sh` | Bumps the pinned Horizon release (version/url/hash) in `nix/sources.json` — see Version Bump Procedure above. |
| `nix/check-self-update.sh` | UPD-01/UPD-02 — confirms Horizon's self-update is neutralized (no binary rewrite, no `$HOME` shadow copy). Needs a virtual display (`xvfb-run`). |
| `nix/check-home-passthrough.sh` | RUN-01 — confirms `~/.minecraft`/`HORIZON_MINECRAFT_DIR` passthrough works correctly and the sandbox narrowing doesn't leak anything else from `$HOME`. |
| `nix/check-oauth-reachability.sh` | RUN-02 — confirms the Microsoft OAuth device-code mechanism and TLS reachability. Needs real network. |
| `nix/check-desktop-entry.sh` | RUN-03 — confirms the static `.desktop`/icon install is correct and never collides with Horizon's own self-written entry. |

These are all manually-run `apps`/scripts — some need network access or a virtual display, so they are deliberately **not** part of `nix flake check`'s `checks.${system}.*` block (build, desktop-file validation, the Mojang-asset closure scan). Note that `checks.build` still builds the real package via `fetchurl`, so a cold store with no reachable binary cache needs network the first time — Nix's fixed-output-derivation sandbox exemption, not a bug; only the *maintainer-script* layer above is unconditionally network-independent.

## Current Status

Automated and verified: `nix build`/`nix run` (including from a real invocation directory under `$HOME` — a milestone-integration-audit BLOCKER where the sandbox narrowing broke bwrap's `--chdir` was found and fixed), self-update neutralization, `~/.minecraft` passthrough with sandbox narrowing, and the installed `.desktop` entry's file-level correctness (content + no collision with Horizon's own self-write).

Two categories of human verification remain genuinely pending — not fabricated, not glossed over:

- **GPU visual rendering:** a human with a real display still needs to run `nix run .#default` and visually confirm the launcher's GUI actually renders correctly. Tracked in [`.planning/phases/01-bare-working-derivation/01-HUMAN-UAT.md`](.planning/phases/01-bare-working-derivation/01-HUMAN-UAT.md).
- **Real Microsoft sign-in and live desktop-menu rendering:** completing an actual Microsoft sign-in with real credentials, and confirming the `.desktop` entry visually renders correctly in a live desktop environment's application menu. Both tracked in [`.planning/phases/03-runtime-correctness/03-HUMAN-UAT.md`](.planning/phases/03-runtime-correctness/03-HUMAN-UAT.md).
