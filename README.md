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

### Library / Thumbnails

- **Thumbnail loading and caching** on the library page reworked for fewer requests and faster scroll.
- **Stale `arcsize` and `pagecount` recovery** for archives that were replaced on disk under the same path — Shinobu now reconciles cached values against actual file size.

### Performance

A two-tier sweep against the request hot path, based on [`docs/performance-audit.md`](docs/performance-audit.md):

**Tier 0** — trivia wins:
- Cache `is_default_password` (bcrypt ~50–100 ms) and the `(apikey, bearer)` tuple per-worker with 30s TTL, eliminating the bcrypt round and a Redis connection on every index / authenticated API request.
- Hoist `Archive::Libarchive::Peek` out of the `get_filelist` inner loop — lazily constructed once per archive instead of once per `__MACOSX/` entry.
- `decoding="async"` on library thumbnails and index tooltips.
- Configurable GhostScript PDF DPI via `LRR_PDF_DPI` (default 200).
- Configurable Mojo prefork worker count via `LRR_WORKERS` (default 4).

**Tier A** — request hot path:
- **Process-level config cache** — `get_redis_conf` results cached per-worker with a 30s TTL and explicit invalidation on config write. Removes 6–8 Redis TCP setup/teardown cycles per request.
- **Plugin namespace lookup hash** — `get_plugin` was an O(N) scan over every loaded plugin calling `plugin_info()`; now a one-shot `%by_namespace` hash. ~200× speedup on Auto-Plugin per-archive runs.
- **Static asset caching** — `Cache-Control: public, max-age=86400` on `/css|js|themes|img/*` responses; `Set-Cookie` skipped on those paths so shared HTTP caches can reuse them.
- **Async page-size lookup** — `LRR.getImgSizeAsync` replaces the sync `$.ajax({ async: false, HEAD })` that blocked the UI thread on every page turn.
- **Deferred script loading** — `defer` applied to all `<script src>` tags across 13 templates; the inline React alias moved to `react-alias.js`; inline scripts that depend on libs wrapped in `DOMContentLoaded`. Unblocks the initial HTML parse on slow networks.
- **Pipelined Redis bulk fetches** — duplicate-finder `thumbhash` reads, backup metadata, and plugin metadata use `HMGET` + `wait_all_responses` instead of N sequential round-trips; `clean_database` downgraded from `HGETALL` to `EXISTS` for existence checks.

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
