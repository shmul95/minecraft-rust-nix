<!-- GSD:project-start source:PROJECT.md -->
## Project

**Horizon Nix Package**

A Nix flake that packages the [Horizon launcher](https://github.com/horizon-rust/horizon) — a from-scratch Rust reimplementation of Minecraft: Java Edition — so it can be installed and launched declaratively on NixOS / via Nix on any Linux system. The flake pulls the official Horizon launcher binary (or builds it from source), wires up its runtime dependencies (Vulkan/OpenGL, audio, input libs), and exposes a runnable `horizon-launcher` package/app, letting the user "play Minecraft Rust Edition" with a single `nix run` or NixOS module, instead of manually managing a loose AppImage.

**Core Value:** Running `nix run .#horizon-launcher` (or installing the flake's package) launches a working Horizon launcher on the user's NixOS machine, with all native dependencies resolved — no manual AppImage babysitting, no missing `.so` errors.

### Constraints

- **Platform**: Linux/NixOS only — no macOS/Windows packaging in this project.
- **Legal**: Must not bundle Minecraft or Horizon binary assets owned by Mojang; user supplies their own copy. The flake packages tooling only.
- **Licensing**: Horizon is MIT; respect THIRD_PARTY_NOTICES from upstream when redistributing/patching binaries.
- **Self-update conflict**: Horizon launcher normally self-updates; packaging in the immutable Nix store means the flake must pin versions explicitly and document the upgrade path (bump a hash/version in the flake) rather than relying on in-place updates.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `pkgs.fetchurl` | nixpkgs 25.11 / unstable | Pin + hash-verify the official `horizon-launcher-linux-x86_64.AppImage` release asset | Standard, minimal way to turn a mutable upstream URL into a content-addressed, reproducible Nix input. This is what directly satisfies the "pin a version" requirement in PROJECT.md — the hash makes the store path immutable, so Horizon's self-updater can never silently change what `nix build` produces. |
| `pkgs.appimageTools.wrapType2` | nixpkgs 25.11 / unstable | Primary packaging technique: extracts the AppImage and runs its payload inside a `buildFHSEnv` (bubblewrap) sandbox with a curated library set | This is the **canonical, nixpkgs-manual-documented** way to package a prebuilt AppImage (confirmed against `pkgs/build-support/appimage/default.nix` on nixpkgs `master`). Its `defaultFhsEnvArgs.multiPkgs` **already includes `vulkan-loader`, `alsa-lib`, `udev`, `libGL`, `wayland`, `libxkbcommon`, `openssl`, `freetype`, `fontconfig`** — i.e. essentially everything Horizon's README lists as a Linux runtime requirement, with zero `extraPkgs` tuning needed on day one. This drastically lowers the "guess which `.so` is missing" iteration loop compared to hand-rolling library lists. |
| `pkgs.appimageTools.extract` | nixpkgs 25.11 / unstable | Pulls the AppImage's squashfs payload (binary, icons, `.desktop` file, bundled libs) into a plain directory, used both internally by `wrapType2` and directly if you choose the autoPatchelf alternative | `extractType1`/`extractType2` are deprecated aliases for this one unified function as of current nixpkgs master — always call `extract` directly if you need the raw AppDir contents (e.g. to pull out the icon/`.desktop` for `extraInstallCommands`). |
| `autoPatchelfHook` + `makeWrapper` (`nativeBuildInputs`) | nixpkgs 25.11 / unstable | **Alternative/fallback** packaging technique: patch the extracted ELF binary's interpreter + RPATH directly instead of sandboxing it in an FHS chroot | Lighter-weight than `wrapType2` (no bubblewrap/user-namespace requirement at runtime, no sandbox startup cost), fully transparent (`ldd`-able), and lets you inject the self-update-disable env var in the *same* derivation via `wrapProgram --set`. This is the standard idiom nixpkgs uses for prebuilt native binaries that are *not* complex Electron/GTK apps (Discord's `base.nix`, countless `pkgs/by-name/*` binary wrappers). Recommended as the escape hatch if `wrapType2`'s FHS sandbox causes friction (e.g. restricted CI sandboxes without user namespaces, or if GPUI's windowing backend behaves oddly inside bubblewrap). |
| Nix Flakes (`flake.nix`, `apps.default`, `packages.default`) | Nix ≥ 2.18 (ships with NixOS 25.11+) | Entry point: `nix run`, `nix build`, `nix develop` | This is the project's explicit deliverable shape (per PROJECT.md: "Nix flake exposes `packages.horizon-launcher`... `apps.default`"). Standard flake schema, no exotic flake-parts/flake-utils dependency strictly required for a single-package flake, though `flake-utils.lib.eachDefaultSystem` is a reasonable convenience if multi-arch support is ever wanted (Horizon currently only ships x86_64 Linux). |
### Supporting Libraries (runtime `buildInputs` / `runtimeDependencies`)
| Library | Purpose | When to Use |
|---------|---------|-------------|
| `vulkan-loader` | Vulkan ICD loader (`libvulkan.so.1`) | Always — Horizon's README states "Vulkan or OpenGL 3.3" as the GPU requirement; GPUI's renderer is Vulkan-first on Linux. **Must be injected via `runtimeDependencies` (autoPatchelf path) or rpath, not just `buildInputs`** — Vulkan loaders are `dlopen`'d at runtime, not linked at build time, so plain `autoPatchelfHook` dependency resolution (which only looks at ELF `DT_NEEDED` entries) will *not* find it automatically. Confirmed by both the Upscayl AppImage case (`libvulkan.so.1` not found until `vulkan-loader` added to `extraPkgs`) and Zed's own `postFixup` (`patchelf --add-rpath` explicitly adding `vulkan-loader` even after a full Rust build). |
| `libGL` (mesa) | OpenGL / GLX fallback path | Always — covers the "or OpenGL 3.3" half of Horizon's GPU requirement and is `dlopen`'d the same way Vulkan is. |
| `alsa-lib` | Audio output (ALSA) | Always — explicit Horizon build dep (`libasound2-dev`). |
| `udev` (`systemd`'s libudev) | Device/controller enumeration | Always — explicit Horizon build dep (`libudev-dev`); typically pulled in by Rust gamepad/input crates (e.g. `gilrs`/`rodio`-adjacent) at runtime via `dlopen` or dynamic linking. |
| `wayland` + `libxkbcommon` | Wayland display backend + keyboard layout handling | Always on current NixOS — GPUI (via Zed precedent) links/dlopens both, needed for Wayland sessions and keymap handling even under XWayland. |
| `libxcb`, `libx11`, `libxext` | X11 fallback display backend | Always — GPUI (like Zed) supports an X11 backend in addition to Wayland; needed for X11 sessions and as a safety net. |
| `fontconfig`, `freetype` | Font discovery + glyph rasterization | Always — GPUI renders its own UI text natively (no browser engine), these are standard text-stack deps. |
| `openssl` | TLS for HTTPS (Microsoft OAuth device-code flow, Mojang/launcher API calls, self-update check requests) | Always — Horizon talks to Microsoft identity endpoints and its own update server over HTTPS. |
| `glib` | Low-level GNOME platform glue, often an indirect dep of GPUI's Linux backend (same as Zed) | Always, cheap to include. |
| `zlib`, `zstd` | Compression (asset/update-payload decompression) | Likely — included defensively; cheap, no downside to having present. |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| `nix flake check` | Validates the flake evaluates and `packages.*`/`apps.*` are well-formed | Run before every commit touching `flake.nix`. |
| `nixpkgs-fmt` / `nixfmt-rfc-style` | Formatting | Either is fine; `nixfmt-rfc-style` is the direction nixpkgs itself is standardizing on as of 2025/2026. |
| `statix` | Lint for common Nix anti-patterns | Optional but catches things like unnecessary `with`, unused `rec`. |
| `nix run nixpkgs#steam-run -- ./horizon-launcher-linux-x86_64.AppImage` | **Dev-only** quick smoke test of the raw upstream AppImage in an FHS sandbox, before writing any derivation | Fast way to confirm the binary runs *at all* on NixOS and to `strace -f -e openat` it for the real dlopen'd library list, before committing to a `buildInputs` set. Not part of the shipped package. |
| `appimage-run` (`programs.appimage.binfmt = true`) | NixOS module to register AppImages with the kernel's binfmt handler | **Do not rely on this as the shipped solution** — see "What NOT to Use". Useful only for a one-off manual test. |
## Installation
# flake.nix skeleton
# nix/horizon-launcher.nix — Primary recommendation: appimageTools.wrapType2
# Wrap again to inject the self-update opt-out before exec'ing into the
# FHS-sandboxed binary — wrapType2's own runScript is computed internally
# and can't be overridden directly, so this outer layer is the clean way in.
# nix/horizon-launcher.nix — Alternative: extract + autoPatchelf + makeWrapper
# (lighter weight, no bwrap sandbox; use if wrapType2's FHS sandbox causes
# friction, e.g. restricted CI without user namespaces)
## The Self-Update vs. Read-Only Store Conflict — Concrete Pattern
- The launcher checks for a newer build on startup and every 30 minutes while open; on finding one it **downloads the new build and replaces its own binary in place**, then offers "Restart".
- Setting the environment variable **`HORIZON_LAUNCHER_NO_SELF_UPDATE=1`** makes the launcher never attempt to replace itself — this is the documented behavior for "development builds," and is exactly what a Nix package needs.
- There is a second, complementary variable, **`HORIZON_LAUNCHER_DESKTOP_EXEC`**, explicitly intended for packagers: it lets the launcher know the "real" absolute path of the wrapper it was invoked through, so any desktop-entry / "Restart" logic points back at the Nix-managed wrapper rather than the (immutable, unwritable) extracted binary path.
| Package | Pattern | Applicable to Horizon? |
|---|---|---|
| `zed-editor` (nixpkgs) | Build-time env var (`ZED_UPDATE_EXPLANATION`) baked in because Zed is compiled from source by nixpkgs | No — we don't compile Horizon. Confirms the *general* "env var disables self-updater" idiom is well-established, but the injection mechanism must shift to runtime (`makeWrapper --set`) for a prebuilt binary. |
| `steam` (nixpkgs) | Ships only a thin bootstrap in the Nix store; the real Steam client lives in `~/.local/share/Steam` and self-updates there, entirely outside the store | Not recommended for Horizon — Steam's architecture has a separate "client" the bootstrap downloads; Horizon *is* the single binary that tries to overwrite itself, so there's no natural "thin shim + mutable client dir" split to exploit without re-implementing Horizon's update logic yourself. Pin + disable is simpler and matches PROJECT.md's stated decision. |
| `heroic-unwrapped` (Electron, nixpkgs) | Electron's own `autoUpdater` API requires `app.isPackaged` + a signed update feed to activate; running from an extracted/unsigned Nix build typically means it silently never triggers — no explicit opt-out needed | Not directly applicable — Horizon's updater is a bespoke binary-replacement routine, not gated by packaging metadata, so it *will* actively try and fail (or succeed destructively) unless explicitly told not to via `HORIZON_LAUNCHER_NO_SELF_UPDATE`. |
| `hytale-launcher` (nixpkgs PR #479368), `rbxport`, `moeru-ai/airi` | Same family of problem (prebuilt self-replacing launcher binary): either set a `*_DISTRIBUTION=nix`-style env var the app checks, or let the self-update fail loudly with a harmless "read-only file system" error that doesn't crash the app | Directly analogous — confirms "explicit env var opt-out via wrapper" is the current (2025/2026) community-standard idiom for exactly this shape of problem, and Horizon conveniently already ships the hook for it. |
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|--------------------------|
| `appimageTools.wrapType2` | `autoPatchelfHook` + `makeWrapper` on `appimageTools.extract` output | Use when you want a lighter-weight, sandbox-free executable (no bubblewrap/user-namespace dependency, easier to debug with `ldd`), when running inside environments where bubblewrap/user namespaces are unavailable (some CI sandboxes, some containers), or if GPUI's Wayland/X11 backend behaves oddly when run inside an FHS bubblewrap chroot (unverified risk — test both). |
| `appimageTools.wrapType2` / autoPatchelf | `buildFHSEnv` directly (hand-rolled, e.g. `steam-run`-style) | Only for throwaway manual testing/debugging of the raw upstream AppImage before writing a real derivation (`nix run nixpkgs#steam-run -- ./horizon.AppImage`). Not suitable as the shipped artifact: no hash pinning, no desktop integration, no self-update neutralization. |
| `appimageTools.extract` | `ralismark/nix-appimage` | **Never for this task** — `nix-appimage` solves the *opposite* problem (bundling an arbitrary Nix derivation + its closure into a new, portable AppImage for distribution on non-Nix systems). It is not a tool for consuming/unpacking an existing third-party AppImage. Don't be misled by the similar name. |
| Pin via `fetchurl` + explicit `hash` | Build Horizon from source (`cargo build --release`) via the documented Rust 1.90+/Python 3.10+/JDK 25 toolchain | Fall back to this only if the official Linux AppImage proves unusable on NixOS (e.g. incompatible glibc symbol versions that `patchelf`/`autoPatchelf` genuinely can't bridge — rare, since glibc is strongly backward compatible). PROJECT.md already scopes this as the documented fallback, not the default path. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Plain `fetchurl` + `chmod +x` + direct exec, with no patching/wrapping at all | The AppImage's own embedded ELF binaries (both its outer FUSE-mount bootstrap stub and the Rust payload inside) are linked against the standard `/lib64/ld-linux-x86-64.so.2` + FHS-style library search paths. NixOS has neither — there is no `/lib64`, no `/usr/lib`, nothing at the hardcoded interpreter path. You will get "No such file or directory" even though the file plainly exists; this is the single most common NixOS AppImage confusion and is explicitly called out across every source consulted (NixOS wiki Appimage page, multiple Discourse threads). | `appimageTools.wrapType2` or `appimageTools.extract` + `autoPatchelfHook`. |
| Relying on `programs.appimage.binfmt = true` (`appimage-run`) as the *shipped* solution | This NixOS module registers AppImages with the kernel binfmt handler so double-clicking/executing one "just works" by transparently running it through an FHS sandbox — but it does nothing about hash-pinning, reproducibility, desktop integration, or (critically) Horizon's self-update conflict: the fetched AppImage file would still sit at a read-only Nix store path (or an arbitrary user-downloaded path), and Horizon would still attempt — and fail or misbehave — in-place self-replacement with no opt-out wired in. Fine for a 30-second manual smoke test only. | `appimageTools.wrapType2` with the `HORIZON_LAUNCHER_NO_SELF_UPDATE` wrapper pattern above. |
| `ralismark/nix-appimage` / `pkgforge/nix-appimage` | Wrong direction entirely — these convert a Nix derivation *into* a new AppImage for portability on non-Nix systems. They do not help you consume Horizon's existing AppImage. | `appimageTools.extract` / `appimageTools.wrapType2`. |
| Letting Horizon's self-updater run unmodified and just "see what happens" | Observed behavior across structurally identical cases (hytale-launcher, rbxport, airi) ranges from a harmless logged "read-only file system" error to the updater actually succeeding in writing a *new* file next to the original (if any writable directory happens to be in scope) and leaving the installation in an inconsistent, unreproducible state that no longer matches the pinned flake input. Either outcome defeats the entire point of packaging this with Nix. | Explicit `HORIZON_LAUNCHER_NO_SELF_UPDATE=1` via `makeWrapper --set`. |
| Hand-listing only the libraries you *think* you need for a Vulkan/wgpu Rust binary and relying solely on `autoPatchelfHook`'s automatic `DT_NEEDED` resolution | GPU loader libraries (`vulkan-loader`, `libGL`) and several audio/ALSA plugin libs are loaded via `dlopen()` at runtime, not declared as ELF `DT_NEEDED` entries — `autoPatchelfHook` cannot discover these automatically, and you will get runtime "failed to find any Vulkan driver"/ICD-not-found errors despite a clean `autoPatchelf` build log. This exact failure mode is independently confirmed by both the Upscayl AppImage case and Zed's own `postFixup` needing a manual `patchelf --add-rpath` for the same three libraries. | Explicit `runtimeDependencies = [ vulkan-loader libGL ];` (autoPatchelf path) or rely on `wrapType2`'s `defaultFhsEnvArgs`, which already includes them. |
## Stack Patterns by Variant
- Use `appimageTools.wrapType2` with empty `extraPkgs`.
- Because its `defaultFhsEnvArgs` already ships `vulkan-loader`, `alsa-lib`, `udev`, `libGL`, `wayland`, `libxkbcommon`, `openssl`, `fontconfig`, `freetype` — i.e. the entire Horizon Linux dependency surface — out of the box.
- Use `appimageTools.extract` + `autoPatchelfHook` + `makeWrapper`, with `runtimeDependencies` covering the `dlopen`'d Vulkan/GL libs explicitly.
- Because `wrapType2`'s `buildFHSEnv`-based sandbox requires working Linux user namespaces at runtime, which some CI runners/containers restrict.
- Fall back to building Horizon from source via `rustPlatform.buildRustPackage`, pulling in the documented build deps (Rust 1.90+, Python 3.10+, JDK 25, `alsa-lib`, `udev`).
- Because PROJECT.md already scopes this as the explicit fallback path, not the default.
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| `horizon-launcher-linux-x86_64.AppImage` (upstream glibc, likely built on an older Ubuntu base per common AppImage practice) | NixOS 25.11+ `glibc` (2.40+) | glibc maintains strong backward symbol compatibility — a binary linked against an older glibc runs fine against a newer one. The risky direction (newer binary, older runtime) does not apply here. Low risk; `patchelf`-rewriting the interpreter/RPATH is sufficient, no `glibc`-version pinning expected to be needed. |
| `appimageTools.wrapType2` | nixpkgs `nixos-25.11` and `nixos-unstable` | Function signature (`extract`/`wrapType2`/`defaultFhsEnvArgs`) confirmed stable on current nixpkgs `master` as of 2026-11-01; `extractType1`/`extractType2`/`wrapType1` are deprecated-but-functional aliases, safe to avoid but not yet removed. |
| `autoPatchelfHook` + separate `patchelf` nativeBuildInput | — | **Do not add plain `patchelf` as a nativeBuildInput alongside `autoPatchelfHook`** if also using `runtimeDependencies` — the plain `patchelf` setup-hook's own cleanup step is known to strip RPATH entries added by `autoPatchelfHook`'s `runtimeDependencies` handling (nixpkgs issue #43082). Use `autoPatchelfHook` alone, or set `dontPatchELF = true` if you genuinely need both. |
## Sources
- `https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/appimage/default.nix` (fetched verbatim via `curl`) — HIGH confidence, exact current source for `extract`/`wrapType2`/`wrapAppImage`/`defaultFhsEnvArgs`.
- `https://wiki.nixos.org/wiki/Appimage` — HIGH confidence, official NixOS wiki guidance on `wrapType2`/`fetchurl` pinning pattern.
- `https://discourse.nixos.org/t/creating-a-nix-derivation-for-an-appimage/31927` and `https://discourse.nixos.org/t/appimage-derivation/21735` — MEDIUM confidence, community examples corroborating `wrapType2` usage pattern.
- `https://discourse.nixos.org/t/create-upscayl-derivation-cant-find-libvulkan-so-1/21881` — MEDIUM confidence, real-world confirmation that `vulkan-loader` must be added explicitly (dlopen, not DT_NEEDED) for AppImage-wrapped apps.
- `https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-unstable/pkgs/by-name/ze/zed-editor/package.nix` (fetched verbatim via `curl`) — HIGH confidence, closest real nixpkgs analog for a GPUI-based native Rust Linux desktop app: exact `buildInputs`, `postFixup` rpath additions for `libGL`/`vulkan-loader`/`wayland`, and the `ZED_UPDATE_EXPLANATION` self-update-disable pattern.
- `https://github.com/NixOS/nixpkgs/pull/479368` (hytale-launcher) — MEDIUM confidence (summarized via WebFetch, not raw-fetched), corroborates the "env var opt-out for a prebuilt self-replacing launcher binary under Nix" pattern as an established, recurring idiom in 2025/2026 nixpkgs contributions.
- `https://github.com/horizon-rust/horizon` README (fetched directly, cross-checked via two independent fetches) — MEDIUM confidence, source for `HORIZON_LAUNCHER_NO_SELF_UPDATE` / `HORIZON_LAUNCHER_DESKTOP_EXEC`, GPUI UI framework, device-code MS auth flow, and the `libasound2-dev libudev-dev` build dependency list. Recommend re-verifying directly against the repo at implementation time, since this was read via an AI-summarizing fetch tool rather than a raw text diff.
- `https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/setup-hooks/auto-patchelf.sh` and `https://ryantm.github.io/nixpkgs/hooks/autopatchelf/` — HIGH confidence, `autoPatchelfHook`/`runtimeDependencies` semantics.
- `https://github.com/NixOS/nixpkgs/issues/43082` — MEDIUM confidence, the `patchelf` + `runtimeDependencies` interaction caveat.
- `https://github.com/ralismark/nix-appimage` — HIGH confidence (direct fetch), confirms this tool solves the opposite problem and should not be used here.
- `https://nixos.org/blog/announcements/2025/nixos-2511/` and related Discourse/Phoronix coverage — HIGH confidence, confirms NixOS 25.11 as current stable baseline as of this research date (2026-11-01).
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
