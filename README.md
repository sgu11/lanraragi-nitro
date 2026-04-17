# Customized LANraragi

A personal fork of [LANraragi](https://github.com/Difegue/LANraragi) with reader, theming, and reliability enhancements focused on a deployed library running on filesystem.

This fork is maintained by AI agents (Claude Code) under human direction. Changes are **not** submitted as pull requests to the upstream project, as the code is AI-generated. This repository periodically merges upstream updates from the official LANraragi.

---

## Patch Notes (vs. upstream)

### Reader

- **Auto-fullscreen** option that enters fullscreen on archive open and exits cleanly on leave (with `fscreen` polyfill for older browsers).
- **Image quality** options exposed in settings, with a working mobile toggle.
- **Fit-height fix in fullscreen** — recomputes correct height on enter/exit instead of leaving stale layout.
- **Double-page rendering** no longer flickers between page transitions.

### Library / Performance

- **Thumbnail loading and caching** on the library page reworked for fewer requests and faster scroll.
- **Stale `arcsize` and `pagecount` recovery** for archives that were replaced on disk under the same path — Shinobu now reconciles cached values against actual file size.

### Server reliability

- **filesystem-aware Shinobu file watcher** — detects inode-number changes after a `filesystem receive` / dataset-swap and re-creates the watcher instead of silently losing events.
- **Undef handling** hardened in search and Shinobu paths to avoid log spam on edge-case archives.

### Themes

- New **Catppuccin Mocha** theme.

### Plugins

- New **metadata sidecar plugin** metadata plugin — parses `info.txt` files produced by [metadata sidecar plugin](https://github.com/KurtBestor/metadata sidecar plugin) (distinct format from upstream's `EHDLInfo` plugin).

### i18n

- Korean translations for new reader settings (Image Quality, Auto Fullscreen).
- Translation template entries propagated across all locale `.po` files.

### Docs / Ops

- [`CLAUDE.md`](CLAUDE.md) documents the architecture, build, plugin contract, and code style for AI agents working in this repo.
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) documents the three-tier deployment procedure to the production instance on `deployment target` (hot code-swap, compose edit, image rebuild) with pre-flight, verification, and rollback steps.

---

## Upstream Features

For the full upstream feature list, screenshots, OPDS catalog, plugin system overview, and client API, see the [official LANraragi repository](https://github.com/Difegue/LANraragi) and [LANraragi documentation](https://sugoi.gitbook.io/lanraragi/).

## License

    MIT License

    Copyright (c) 2018 Difegue
    Copyright (c) Contributors to the LANraragi project

    Licensed under the MIT License. See COPYING for the full license text.
