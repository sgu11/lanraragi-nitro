# Customized LANraragi

A personal fork of [LANraragi](https://github.com/Difegue/LANraragi) with reader, theming, and reliability enhancements focused on a deployed library running on filesystem.

This fork is maintained by AI agents (Claude Code) under human direction. Changes are **not** submitted as pull requests to the upstream project, as the code is AI-generated. This repository periodically merges upstream updates from the official LANraragi.

---

## Patch Notes (vs. upstream)

The current merge-preservation baseline lives in [`docs/local-features/`](docs/local-features/README.md). Use those feature documents during upstream syncs to preserve fork-only implementation details, routes, Redis keys, and verification commands.

### Reader

- **Auto-fullscreen** option that enters fullscreen on archive open and exits cleanly on leave (with `fscreen` polyfill for older browsers).
- **Image quality** options exposed in settings, with a working mobile toggle.
- **Fit-height fix in fullscreen** — recomputes correct height on enter/exit instead of leaving stale layout.
- **Double-page rendering** no longer flickers between page transitions.
- **Adaptive double-page spread start** stores server-detected first-page side
  per archive and uses it in `auto` mode, with detection limited to newly
  ingested archives plus a recent-50 backfill job while the heuristic is tuned.
- **Middle-click toggles fullscreen** anywhere in the reader (same as pressing `F`).
- **Reading-progress migration** no longer keeps resurfacing stale migration toasts for deleted archives/tankoubons, and respects local/authenticated progress settings before attempting a server migration.
- **Progression Tracking disabled** now suppresses local/server progress writes during page turns instead of only ignoring saved progress on reader open.
- Technical baseline: [`docs/local-features/reader.md`](docs/local-features/reader.md).

### Library / Thumbnails

- **Thumbnail loading and caching** on the library page reworked for fewer requests and faster scroll.
- **Image-serving pipeline hardening** — hidden compact-table tooltip thumbnails now fetch only on hover, thumbnail-card images use browser lazy loading, missing single-thumbnail requests coalesce behind Redis-backed Minion job locks, and thumbnail responses are inline cacheable image responses instead of downloads.
- **Library default sort** opens the index with `sort=1&sortdir=desc` so the configured Date column is newest-first by default; explicit URL sort parameters and saved non-default sort choices still win.
- **Stale `arcsize` and `pagecount` recovery** for archives that were replaced on disk under the same path — Shinobu now reconciles cached values against actual file size.
- **Bulk archive actions** — the fork's earlier hover-checkbox / bulk-selection-banner design was **superseded by upstream's multi-select mode (MSM)** during the ES-module sync. On the index page the `Select Archives` button turns the thumbnail carousel into a selection panel; click thumbnails (or the right-click `Add to selection` menu) to build a `localStorage`-backed selection, then `Select page`, `Clear`, `Run Batch Operations`, or `Merge into Tankoubon`. The original fork spec is retained for history only: [`docs/superpowers/specs/2026-04-20-bulk-archive-actions-design.md`](docs/superpowers/specs/2026-04-20-bulk-archive-actions-design.md) (superseded).
- **Mobile portrait card sizing fix** — cards were rendering desktop-sized (228×335, 280px thumb box) on portrait phones/tablets around 1440 CSS-px because no media query fired above 560px and the viewport meta omitted `initial-scale=1`. Added `initial-scale=1` to all 15 templates, relaxed the `.id3 img` cap so the image fills its container, added a 561–900px portrait breakpoint (196×296, 236px thumb), and mirrored the `min-height` override at ≤560px so phones actually get 256px cards instead of 335px cards with a blank strip.

### Duplicates

- **Relation-aware duplicate finder** — duplicate review now uses lead-page pHash plus normalized title/source heuristics to classify duplicate, translation variant, subset, and review-only pairs, including suggested delete/keep sides and risk flags.
- Technical baseline: [`docs/local-features/duplicate-detection.md`](docs/local-features/duplicate-detection.md).

### Performance

A sustained sweep against the request hot path, tracked in [`docs/performance-audit.md`](docs/performance-audit.md) (v2 catalog), [`docs/performance-audit-v3.md`](docs/performance-audit-v3.md) (v3 delta + plan), and [`docs/local-features/performance-reliability.md`](docs/local-features/performance-reliability.md) (current implementation baseline). Current baseline measurements in [`docs/performance-baseline.md`](docs/performance-baseline.md).

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
- **Pipelined Redis bulk fetches** — duplicate-finder `thumbhash` reads, backup metadata, and plugin metadata use `HMGET` + `wait_all_responses` instead of N sequential round-trips; `clean_database` downgraded from `HGETALL` to `EXISTS` for existence checks.
- **Page response cache headers (N-1)** — `Cache-Control: private, max-age=3600, immutable` on `/api/archives/{id}/page` so the browser can serve back-button/replay hits without hitting the app. Archive IDs are content-hashed, so the URL is stable for the bytes.
- **`LRR_MCE_WORKERS` env var (N-5)** — plumbs into `MCE::Loop->init` at the Shinobu / Minion mce_loop call sites so over-subscription on small VMs can be tamed without patching.
- **Fresh-install default `archives_per_page` = 30 (B.8)** — faster first paint on mobile for new installs; existing instances keep their configured value.
- **Thumbnail-job race guard (B.9)** — `HSETNX` on the `thumbjob` field closes the TOCTOU between the `-e` probe and `enqueue`; Minion `on_failed` hook `HDEL`s the stale field so failed jobs don't wedge future regeneration.
- **Single thumbnail miss coalescing** — `/thumbnail?no_fallback=true` for archive pages and Tankoubons uses short config-DB lock keys so repeated visible/tooltip misses return the existing active Minion job instead of enqueueing duplicates.
- **Image serving metrics** — Prometheus output includes page-serving request, byte, total duration, archive extraction, and resize counters labeled by image kind, variant, and cache status.
- **Bounded reader preload cache** — reader Blob URL preloads dedupe in-flight fetches, reuse the inline first page when already loaded, and revoke evicted Blob URLs instead of growing unbounded.
- **Inflight-promise dedup in `Server.callAPI` (B.10)** — concurrent GETs to the same URL share a single fetch; the Map self-evicts on settle.
- **Filelist cache (B.1)** — `pagefiles` on the archive hash (Storable-frozen, invalidated by Shinobu on arcsize mismatch and by `change_archive_id`). Reader opens on warm cache skip the libarchive scan — 237 → 49 ms on truly cold archives.
- **Inline first-page `src=` (A.6)** — template sets the reader's `<img src>` to the first page URL when pagefiles cache is warm, so the browser starts the page fetch during HTML parse instead of waiting for the `/files` API.
- **Generation-keyed TTL search cache (B.6)** — `LRR_SEARCHCACHE:$gen:$key` with `EX 300`; `invalidate_cache` bumps `LRR_SEARCHCACHE_GEN` instead of mass-DEL. Old entries expire on their own — no blocking mass delete.
- **Tachiyomi-compatible API hot path** — Tachiyomi/Mihon-style clients get archive-only search results by default, short-lived repeated `/api/search` and one-item random-search caches, a duplicate metadata-call cache, opportunistic `pagefiles` warm jobs, and cacheable inline placeholder thumbnails without requiring an APK rebuild.

**Tier B-redis** — maintained sets + pipelined rebuild:
- **`LRR_ALL_ARCHIVES` / `LRR_CATEGORIES` / `LRR_TANKS` (B.3)** — maintained sets replace every `KEYS '?'x40`, `KEYS 'SET_*'`, `KEYS 'TANK_*'` scan. Lazy backfill from `KEYS` on first read covers existing installs.
- **`LRR_TAG_INDEX_NAMES` (B.4)** — lex-sorted set of `INDEX_*` names, maintained by `update_indexes` and `build_stat_hashes`. Namespaced tag search (`ns:val*`) now resolves via `ZRANGEBYLEX` — true O(log N + M). Bare-tag substring fell back to `KEYS 'INDEX_*val*'` after measurements showed the maintained-set alternatives (ZRANGE+grep, ZSCAN MATCH) cost more than the small keyspace KEYS at this library size.
- **Pipelined `build_stat_hashes` prefetch (B.5)** — one pipelined HMGET per archive for `tags`/`title`/`isnew` instead of 4× sequential HGETs per archive. ~40k round-trips collapse to one on a 10k-archive library.
- **Narrow `get_archive_json` HMGET** — search-row data fetch pulls only the 11 fields that `build_json` actually serializes instead of HGETALL, avoiding the Storable-frozen `pagefiles` blob and other heavyweight fields in the payload.
- **Pipelined callback arg fix** — every `hget`/`hmget` pipelined callback in the codebase (Shinobu, Backup, Stats, Minion dup-finder) was reading `$_[1]` (the error slot) instead of `$_[0]` (the reply), a latent bug inherited from A.8. Caused `LRR_TITLES` / `LRR_TAG_INDEX_NAMES` to stay empty after `build_stat_hashes` and spurious "arcsize mismatch" reconciles at every Shinobu boot. Fixed in-place; the Perl Redis module's pipelined callback signature is `($reply, $error)`, not `($self, $reply)`.

### Server reliability

- **filesystem-aware Shinobu file watcher** — detects inode-number changes after a `filesystem receive` / dataset-swap and re-creates the watcher instead of silently losing events.
- **Undef handling** hardened in search and Shinobu paths to avoid log spam on edge-case archives.
- **Edit route hardening** redirects `/edit` requests without an archive ID before touching Redis, avoiding a protocol-error 500 during smoke checks.

### Themes

- New **Catppuccin Mocha** theme.

### Plugins

- New metadata plugin that parses sidecar `info.txt` files bundled with archives (distinct format from upstream's `EHDLInfo` plugin). Archives without the info.txt log at INFO and return empty (silent skip) instead of raising an ERROR — on a library with mixed sources, Auto-Plugin would otherwise flood the log.

### i18n

- Korean translations for new reader settings (Image Quality, Auto Fullscreen).
- Translation template entries propagated across all locale `.po` files.

### Docs / Ops

- [`AGENTS.md`](AGENTS.md) documents the architecture, build, plugin contract, and code style for AI agents working in this repo.
- [`docs/local-features/`](docs/local-features/README.md) records current fork-only feature baselines for future upstream merges.
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) documents the three-tier deployment procedure to the production instance (hot code-swap, compose edit, image rebuild) with pre-flight, verification, and rollback steps.
- Upstream sync 2026-06-09: merged upstream `dev` through `bebac1aa`, adopting path-based JS cache busting, the extracted index context-menu module, Tankoubon progress/API fixes, log-rotation fallback handling, and build dependency updates while preserving fork reader and duplicate-detection contracts.

---

## Upstream Features

For the full upstream feature list, screenshots, OPDS catalog, plugin system overview, and client API, see the [official LANraragi repository](https://github.com/Difegue/LANraragi) and [LANraragi documentation](https://sugoi.gitbook.io/lanraragi/).

## License

    MIT License

    Copyright (c) 2018 Difegue
    Copyright (c) Contributors to the LANraragi project

    Licensed under the MIT License. See COPYING for the full license text.
