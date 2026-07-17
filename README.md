# Customized LANraragi

A personal fork of [LANraragi](https://github.com/Difegue/LANraragi) with reader, theming, and reliability enhancements focused on a deployed library running on filesystem.

This fork is maintained by AI coding agents under human direction. Changes are **not** submitted as pull requests to the upstream project, as the code is AI-generated. This repository periodically merges upstream updates from the official LANraragi.

Korean version: [`README.ko.md`](README.ko.md).

---

## Patch Notes (vs. upstream)

The current merge-preservation baseline lives in [`docs/local-features/`](docs/local-features/README.md). Use those feature documents during upstream syncs to preserve fork-only implementation details, routes, Redis keys, and verification commands.

### Fork review hardening (2026-07-15)

- **Proportional deployment environment delivery contract** — routine feature fork changes now use changed-surface validation plus short HTTP/Valkey/Shinobu/Minion readiness, while structural/data/runtime/dependency work keeps the full gate, mount/OpenAPI/vendor guards, rollback tuple, and Redis backup where applicable. Public multi-platform, Windows, Homebrew, MSI, Docker Hub, and GitHub Release artifacts run only by manual dispatch or an explicit public release trigger.

- Duplicate review now rejects unsafe archive-member paths before extraction,
  escapes archive metadata through the shared HTML encoder, and imports the
  cache-busted `lrr-common` module.
- Interrupted archive ingestion remains retryable through a pending file-map
  marker, while Minion retains the lease for retryable failures and releases it
  only after a terminal failure.
- Cover duplicate rebuilds pipeline Redis state reads, reader metadata ignores
  stale asynchronous size results, and legacy spread-start values serialize to
  the supported `auto`/`pair2` contract.
- metadata sidecar plugin bare tags are normalized into the `tag:` namespace, and
  the OpenAPI document now matches duplicate status filtering, cover review
  responses, and Tachiyomi-family `groupby_tanks` defaults.

### Upstream sync (2026-07-12)

- Merged upstream through `b94e4805`, including `.cbw` archive support, search
  initialization retry behavior, Redocly OpenAPI validation, and the esbuild
  Swiper vendor bundle. The fork reader implementation now lives behind the
  upstream-style `reader.js` entry in `public/js/mod/reader_common.js`, while
  retaining the documented spread, crop, progress, cache, and chrome contracts.
- The legacy `/duplicates` URL now redirects to the fork's canonical
  cover-focused `/duplicates_custom` review flow, avoiding the incompatible
  upstream duplicate-group and fork pair-deck data models.
- Post-merge stabilization restores the generated Swiper carousel entrypoint,
  native reader paginator controls, and thumbnail-link behavior, while removing
  inactive reader modules that could drift from the deployed runtime.
- CBW remote pages now use redirect-by-redirect public-address validation,
  pinned peer checks, bounded raster decoding, and XML-content-keyed caches;
  private-network CBW image URLs are intentionally rejected.

### Reader

- **Reader failure recovery and accessibility** — page fetch/decode failures
  cancel pending navigation, clear queued input, and show an inline retry;
  overlays use dialog semantics/focus return, controls have 44px targets, and
  reduced-motion preferences are respected.
- **Large archive overview windowing** — thumbnail overview construction is
  deferred until opened and capped at 60 pages per navigable window.
- **Single-page spread alignment** hides the empty secondary image slot after
  an unpaired final page, keeping the page centered and preventing an RTL
  ghost page at the end of odd-length archives.
- **Page-number keyboard jumps** keep conventional behavior in manga mode:
  `Home`/`End` select the first/final numbered page and `Page Up`/`Page Down`
  move backward/forward 10 page numbers, while horizontal page-turn controls
  remain reading-direction-aware.

- **Auto-fullscreen** option that enters fullscreen on archive open and exits cleanly on leave (with `fscreen` polyfill for older browsers).
- **Reader cursor auto-hide** hides the mouse cursor over the page area after
  one second without qualifying mouse movement, hides immediately after
  navigation input (`W/A/S/D`, arrows, or wheel page turns), and restores after
  50px of mouse movement.
- **Image quality** options exposed in settings, with a working mobile toggle.
- **Blank border cropping** can be toggled from the reader chrome, Reader
  Options, or with `K`;
  reader page preloads request cached `/api/archives/{id}/page?crop=border`
  variants with the crop algorithm version in the query string, so browser
  caches are busted when crop policy changes. The full-image link keeps
  pointing at the original page.
- **Blank border crop toolbar icon** reflects the active crop setting with
  `fa-crop` for enabled and `fa-crop-alt` for disabled.
- **Blank border crop redraws** preserve shifted double-page spreads instead of
  snapping them back to the canonical pairing.
- **Blank border cropping** now uses libvips first, skips cover/landscape
  spread pages, and uses per-edge light/dark strip detection inspired by
  Komikku while preserving the outer 2px edge-noise guard. Crop variants are
  accepted or rejected by cropped area percentage only: candidates that remove
  less than 5% of page area are treated as no-crop, while meaningful border
  removals are served and cached even when re-encoding grows the page bytes.
  Crop timing is recorded in metrics.
- **Blank border crop area guard** reads original/cropped dimensions with
  libvips first and treats ImageMagick as optional fallback, so deployments
  without PerlMagick do not return 500 after a successful server crop. The
  entire PerlMagick probe (`new`, `BlobToImage`, `Get`) is wrapped in `eval`,
  so a partially-broken Image::Magick install (e.g. missing dylib at runtime)
  also degrades gracefully instead of crashing the request.
- **Blank border crop fallback** retries the original page when a crop-variant
  preload returns a non-2xx response, so a crop-serving failure does not leave
  the reader on a broken image.
- **Reading-progress resume** preserves shifted double-page spreads such as
  `5 + 6` instead of snapping reloads back to the canonical pairing.
- **Infinite-scroll reader spacing** now uses zero vertical image margin in the
  normal infinite-scroll layout.
- **Fit modes upscale reader pages** so blank-border-cropped and naturally small
  images fill the selected height, width, default/custom container, or fullscreen
  viewport instead of staying at their smaller natural size.
- **Fit-height fix in fullscreen** — recomputes correct height on enter/exit
  instead of leaving stale layout.
- **Double-page rendering** no longer flickers between page transitions.
- **Adaptive offset** keeps covers and wide pages single, stores server-detected
  `Pair 2-3` / `Pair 3-4` hints per archive, and exposes a simple on/off reader
  setting. The detector uses libvips first and ImageMagick only as fallback, so
  libvips-only deployments can still classify early interior pages.
- **Delete key in reader** opens the standard archive/tankoubon deletion
  confirmation modal and returns to the library after confirmed deletion.
- **Header hidden reader layout** now uses the same minimal chrome as infinite
  scroll while preserving normal paginated rendering, double-page mode, stamps,
  and tap/keyboard navigation; it also hides bottom utility links and gives the
  image a full-height no-scroll viewport. Mouse wheel up/down also navigates
  pages in this mode, matching fullscreen behavior, with a shorter local-service
  debounce for more responsive page turns, and pauses while Reader Options is
  open. Side utility icons stack vertically in the minimal layout.
- **Single-page spread sliding** in double-page fullscreen/hidden-header mode:
  `Up`/`W` move the visible spread back by one page and `Down`/`S` move it
  forward by one page. After a one-page slide, normal prev/next navigation keeps
  the shifted double-page stride until a direct page jump or display-mode change
  resets it.
- **Middle-click toggles fullscreen** anywhere in the reader (same as pressing `F`).
- **Reader chrome button clicks** no longer bubble into tap-zone page
  navigation, so bookmark/fullscreen controls do not also turn the page.
- **Reading-progress migration** no longer keeps resurfacing stale migration toasts for deleted archives/tankoubons or malformed local page values, and respects local/authenticated progress settings before attempting a server migration.
- **Reading-progress migration startup** tolerates mixed cached JS modules after deploy, so index load no longer depends on a freshly fetched `common.js`.
- **Fresh reader startup** resolves reader dependencies through deploy-specific
  import-map URLs, so a newly cache-busted `reader.js` cannot pair with a stale
  cached `reader-spread.js` and leave the reader stuck at `... / ...`.
- **Progression Tracking disabled** now suppresses local/server progress writes during page turns instead of only ignoring saved progress on reader open.
- **Reader session page** now stays in the URL while reading, so reloads and
  infinite-scroll fullscreen exits keep the visible page even when Progression
  Tracking is disabled.
- **Reader session URLs** preserve shifted double-page spreads, so reloading a
  shifted `?p=` page does not snap back to the canonical spread start, and
  prev/next navigation resumes the normal double-page stride.
- **Reader early page-turn input** no longer advances invisible pending pages:
  rapid key/tap navigation while a page is still loading is coalesced through a
  reader cursor, so it resolves to the next rendered page instead of skipping
  ahead several pages at once.
- **Cold double-page navigation** renders the requested page before background
  readahead, so a cold cover page is no longer blocked by neighbor probes.
- **Reader session state is separate from synced progress**: the active page is
  committed to the reading-session URL on render/scroll, while synced progress
  is only an opening hint when no explicit `?p=` session page is present.
- **Reading-progress resume** is cancellable: stale async page loads can no longer
  scroll back over newer user navigation, disabled progress tracking no longer
  resumes saved progress on open, and enabled tracking coalesces rapid page-turn
  writes before persisting the latest page.
- Technical baseline: [`docs/local-features/reader.md`](docs/local-features/reader.md).

#### Adaptive Offset Detection Details

Adaptive offset is the fork's double-page rule for standalone manga archives.
The cover is always shown alone as the title cover. The reader then decides
whether the first interior spread starts at **Pair 2-3** or **Pair 3-4**, with
wide/landscape pages kept single and excluded from spread pairing.

Persistent archive fields:

* Stores your comics in archive format. (zip/rar/targz/lzma/7z/xz/cbz/cbr/cbw/pdf supported, barebones support for epub)

- `spreadstart`: reader preference. `auto` enables adaptive detection; `pair2`
  disables it and always starts interior pairing at pages 2-3.
- `firstspreadstart`: detector result, stored as `2`, `4`, or `UNKNOWN`.
- `firstspreadstart_confidence`, `firstspreadstart_reason`,
  `firstspreadstart_v`: detector metadata and algorithm version.
- Legacy `firstpageside*` fields are cleared when archive content changes, but
  no longer drive the reader.

Detection lifecycle:

- New uploads and Shinobu-discovered archives enqueue
  `detect_first_spread_start`.
- `detect_recent_first_spread_starts` backfills all existing archives by
  default, sorted by archive file mtime. A positive `args=[N]` value can still
  intentionally limit a run to the newest N archives. The `recent` name and
  `detect_recent_first_page_sides` remain only for legacy task compatibility.
- If the archive file changes under the same ID, Shinobu clears old
  `firstspreadstart*` and legacy `firstpageside*` fields before queueing fresh
  detection.

Detection heuristic:

- The detector ignores page 1 (cover) and page 2 as unreliable title/inner-cover
  evidence.
- It samples pages 3-10, skips pages that cannot decode, and treats wide pages
  (`width >= height * 1.20`) as `UNKNOWN`.
- Each sampled page is decoded with libvips first and ImageMagick only as
  fallback, then downscaled to fit within `320x320`. The detector compares
  vertical strips on the left and right edges. The strip width is 10% of the
  sampled width, clamped to at least 4 px and at most half the image width.
- Edge complexity is based on luminance gradients plus darkness. In RTL manga,
  the lower-complexity blank/gutter side identifies whether the page is a left
  or right page.
- Page 3 `LEFT` plus page 4 `RIGHT` votes for Pair 2-3. Page 3 `RIGHT` plus
  page 4 `LEFT` votes for Pair 3-4. Later page samples project the same parity
  rule back to the first interior spread.
- At least two confident interior samples are required. Weak or ambiguous votes
  store `UNKNOWN`, and the reader falls back to Pair 2-3.

Reader behavior:

- `public/js/mod/reader-spread.js` builds display windows from
  `spreadstart`, `firstspreadstart`, current page, and known wide pages.
- Page navigation follows those windows instead of applying a fixed `+/-2`
  offset.
- Pressing `Home`/`End` jumps to the first/final numbered page, and `Page Up`/
  `Page Down` jumps backward/forward 10 page numbers. These page-number jumps
  do not reverse in manga mode; horizontal page-turn controls still do.
- Pressing `J` toggles adaptive offset between `auto` and `pair2`, persisted via
  `PUT /api/archives/{id}/spreadstart?value=<auto|pair2>`.
- Hidden-header/minimal-reader chrome is isolated in
  `public/js/mod/reader-chrome.js` and `public/css/reader-chrome.css`; verify
  it with `npm run smoke:reader-chrome` against a deployed reader.

### Library / Thumbnails

- **Catppuccin library header spacing** collapses the hidden MOTD slot so quick
  filter buttons sit directly under the top menu.
- **Thumbnail loading and caching** on the library page reworked for fewer requests and faster scroll.
- **Image-serving pipeline hardening** — hidden compact-table tooltip thumbnails now fetch only on hover, thumbnail-card images use browser lazy loading, missing single-thumbnail requests coalesce behind Redis-backed Minion job locks, and thumbnail responses are inline cacheable image responses instead of downloads.
- **Library default sort** opens the index with `sort=1&sortdir=desc` so the configured Date column is newest-first by default; explicit URL sort parameters and saved non-default sort choices still win.
- **Stale `arcsize` and `pagecount` recovery** for archives that were replaced on disk under the same path — Shinobu now reconciles cached values against actual file size.
- **Grid bulk archive actions** — the fork bulk-selection path is back on the normal index grid. Short right-click an archive card to select/deselect it; right-long-click an already selected archive card to open bulk actions such as `Run Batch Operations`, category add, delete, remove, and clear. The visible selection banner keeps the common actions flat with `Select all`, `Clear`, and direct `Delete` buttons instead of an actions dropdown. Left-click keeps the normal card behavior. Upstream MSM/carousel/Tankoubon selection code is still retained for merge compatibility, but the fork user path hides those controls and does not expose Tankoubon merge from grid selection. The upstream-friendly structure is documented in [`docs/local-features/library-ux-plugins-themes.md`](docs/local-features/library-ux-plugins-themes.md).
- **Tankoubon full detail API** — `GET /api/tankoubons/{id}/full` always includes `full_data` archive metadata for the returned archive page. `include_full_data=false` is no longer supported on that endpoint; use `GET /api/tankoubons/{id}` when IDs-only Tankoubon metadata is enough.
- **Quick filter buttons fix** — category/tag filter chips (`🆕 New Archives`, `🏷️ Untagged Archives`, category chips) on the library page did nothing when clicked. Root cause was dual ES-module instantiation: the index template loaded entry modules via absolute URLs with a cache-bust query (`/js/$version/mod/index.js?$asset_version`), while sibling modules imported each other via relative specifiers (`./index.js`) that resolve to a URL **without** the query. The browser treated those as two distinct modules and instantiated `index.js` twice, splitting module-level state — `selectedCategory` set by the click handler was never seen by `doSearch()`/`loadCategories()`, so the toggle reverted and no filter reached the backend. Fixed by routing every cross-module import under `public/js/mod/` through importmap aliases (`lrr-index`, `lrr-index-table`, `lrr-index-contextmenu`, `lrr-index-grid-selection`, `lrr-index-order`) so entry and internal imports share one canonical, cache-busted URL. Guarded by `tests/js/asset-cache-source.test.mjs` and `tools/browser/quickfilter-smoke.mjs`.
- **Mobile portrait card sizing fix** — cards were rendering desktop-sized (228×335, 280px thumb box) on portrait phones/tablets around 1440 CSS-px because no media query fired above 560px and the viewport meta omitted `initial-scale=1`. Added `initial-scale=1` to all 15 templates, relaxed the `.id3 img` cap so the image fills its container, added a 561–900px portrait breakpoint (196×296, 236px thumb), and mirrored the `min-height` override at ≤560px so phones actually get 256px cards instead of 335px cards with a blank strip.
- **Inline library deletion refresh** — deleting an archive/tankoubon from the library no longer resets search or reloads the whole page. The current DataTables page redraws in place, trims stale multi-select state, marks the carousel dirty only when needed, and highlights shifted-in replacement rows/cards.
- **Library thumbnail draw batching** — thumbnail-mode cards are buffered during DataTables row creation and swapped into `#thumbs_container` once per draw, reducing repeated live DOM mutation.

### Duplicates

- **Cover-focused duplicate finder** — duplicate review now focuses on cover-image pHash similarity and hides relation/title/source comparison factors from the custom UI.
- **Cover pHash luminance fix** — cover hashes now use 8-bit grayscale luminance instead of clipped GREY16 output, preventing bright but unrelated covers from collapsing to Hamming 0. The cover-hash algorithm version is bumped so `Find cover matches` recomputes stale v1 hashes.
- **One-click cover rebuild** — `Find cover matches` now queues missing cover hashes and automatically requeues the cover sweep, so a fresh library no longer needs a second manual click after hash jobs finish.
- **Cover rebuild idempotence** — repeated rebuild passes track in-flight cover hash jobs, avoid duplicate queue spam, and refresh versioned cover fingerprints when same-ID archive replacements invalidate cover evidence.
- **Focused duplicate review queue** — `/duplicates_custom` now opens one large side-by-side cover comparison at a time, keeps a compact upcoming-pair rail, and advances review actions in place instead of replacing the whole deck after every delete/status decision.
- **Comparison evidence chips** — each side of the duplicate comparison highlights stronger keep signals for page count, archive size, tag count, Korean language, cover resolution, and newer date; resolution is read from the existing `cover_fp` dimensions.
- **Duplicate review training log** — status decisions in `/duplicates_custom` append sanitized review events with pair snapshots, derived features, UI context, and labels to `LRR_COVER_DUPLICATE_REVIEW_EVENTS`; export pages with `GET /api/duplicates/cover/review-events`.
- **No-confirm duplicate deletes** — keep/delete actions in `/duplicates_custom` delete immediately and advance the focused queue without a confirmation modal; the UI now states that destructive behavior explicitly instead of promising a confirmation.
- The fork duplicate finder is mounted at `/duplicates_custom`; legacy `/duplicates` bookmarks redirect to that canonical review flow.
- Technical baseline: [`docs/local-features/duplicate-detection.md`](docs/local-features/duplicate-detection.md).
- Explainer: [`docs/deduplication-advancement-explainer-2026-06-19.md`](docs/deduplication-advancement-explainer-2026-06-19.md) and illustrated Korean HTML view.

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
- **Deploy-specific JS/CSS cache busting** — templates append a deployment-specific asset token to static asset query strings, preventing browsers from mixing stale ES modules with newly deployed templates after fork-only hot deploys.
- **Async page-size lookup** — `LRR.getImgSizeAsync` replaces the sync `$.ajax({ async: false, HEAD })` that blocked the UI thread on every page turn.
- **Pipelined Redis bulk fetches** — duplicate-finder `thumbhash` reads, backup metadata, and plugin metadata use `HMGET` + `wait_all_responses` instead of N sequential round-trips; `clean_database` downgraded from `HGETALL` to `EXISTS` for existence checks.
- **Page response cache headers (N-1)** — `Cache-Control: private, max-age=3600, immutable` on `/api/archives/{id}/page` so the browser can serve back-button/replay hits without hitting the app. Archive IDs are content-hashed, so the URL is stable for the bytes.
- **Bounded image-sized PageCache entries** — Unix `PageCache` sets a 32 MB FastMmap page size and an explicit floor-divided page count, so original/resized/cropped blobs fit without FastMmap expanding a 3,000 MiB cap into a 5,728 MiB mmap. Override with `LRR_PAGECACHE_PAGE_SIZE_MB` when needed.
- **Bounded nested job concurrency** — Minion defaults to two concurrent jobs (`LRR_MINION_JOBS`) and derives per-job MCE workers from the host CPU budget; `LRR_MCE_WORKERS` remains an explicit override.
- **Fresh-install default `archives_per_page` = 30 (B.8)** — faster first paint on mobile for new installs; existing instances keep their configured value.
- **Thumbnail-job race guard (B.9)** — `HSETNX` on the `thumbjob` field closes the TOCTOU between the `-e` probe and `enqueue`; Minion `on_failed` hook `HDEL`s the stale field so failed jobs don't wedge future regeneration.
- **Single thumbnail miss coalescing** — `/thumbnail?no_fallback=true` for archive pages and Tankoubons uses short config-DB lock keys so repeated visible/tooltip misses return the existing active Minion job instead of enqueueing duplicates.
- **Actionable request metrics** — Prometheus output preserves underscore-containing endpoints, includes HTTP status counters and duration histograms for p95/p99 queries, resets search counters on restart, and reports Minion queue/worker state plus Minion/Shinobu process metrics. Redis hot-path increments use real callback pipelines.
- **Bounded reader preload cache** — reader Blob URL preloads dedupe in-flight fetches, reuse the inline first page when already loaded, and revoke evicted Blob URLs instead of growing unbounded.
- **Reader predecode window** — high-memory clients retain the next four reader pages (two on lower-memory clients) and move those decoded `Image` objects directly into the visible DOM. This avoids both repeated 6 MP WebP decode calls and the second decode/paint stall Windows Chromium incurred when a decoded Blob URL was assigned to a different `<img>`. The window remains protected inside the existing eight-entry preload LRU.
- **Inflight-promise dedup in `Server.callAPI` (B.10)** — concurrent GETs to the same URL share a single fetch; the Map self-evicts on settle.
- **Filelist cache (B.1)** — `pagefiles` on the archive hash (Storable-frozen, invalidated by Shinobu on arcsize mismatch and by `change_archive_id`). Reader opens on warm cache skip the libarchive scan — 237 → 49 ms on truly cold archives.
- **Inline first-page `src=` (A.6)** — template sets the reader's `<img src>` to the first page URL when pagefiles cache is warm, so the browser starts the page fetch during HTML parse instead of waiting for the `/files` API.
- **Generation-keyed TTL search cache (B.6)** — `LRR_SEARCHCACHE:$gen:$key` with `EX 300`; `invalidate_cache` bumps `LRR_SEARCHCACHE_GEN` instead of mass-DEL. Old entries expire on their own — no blocking mass delete.
- **Tachiyomi-compatible API hot path** — Tachiyomi/Mihon-style clients get archive-only search results by default, short-lived repeated `/api/search` and one-item random-search caches, a duplicate metadata-call cache, opportunistic `pagefiles` warm jobs, and cacheable inline placeholder thumbnails without requiring an APK rebuild.
- **WebUI responsiveness instrumentation** — debug-gated `localStorage.lrrPerf === "1"` marks and long-task observation cover library draws, carousel rebuilds, reader page turns, and overlay rendering without adding normal-user overhead.
- **Reader infinite-scroll lazy windowing** — infinite scroll now materializes a near-page image window and lazy placeholders instead of creating and waiting for every page image before jumping to the requested page.
- **Reader preload A/B switch** — `localStorage.readerPreloadStrategy = "browser"` can compare browser-managed image cache/preload behavior against the default bounded Blob URL preload path.
- **Reader/library render containment** — repeated thumbnail surfaces use `content-visibility: auto` with intrinsic sizing to reduce offscreen render work.
- **Single-pass index startup** — URL state is decoded once (including literal `%` searches), DataTables sends one initial search, categories load once, and hidden carousel/changelog dependencies are lazy.

**Tier B-redis** — maintained sets + pipelined rebuild:
- **`LRR_ALL_ARCHIVES` / `LRR_CATEGORIES` / `LRR_TANKS` (B.3)** — maintained sets replace every `KEYS '?'x40`, `KEYS 'SET_*'`, `KEYS 'TANK_*'` scan. Lazy backfill from `KEYS` on first read covers existing installs.
- **`LRR_TAG_INDEX_NAMES` (B.4)** — lex-sorted set of `INDEX_*` names, maintained by `update_indexes` and `build_stat_hashes`. Namespaced tag search (`ns:val*`) now resolves via `ZRANGEBYLEX` — true O(log N + M). Bare-tag substring fell back to `KEYS 'INDEX_*val*'` after measurements showed the maintained-set alternatives (ZRANGE+grep, ZSCAN MATCH) cost more than the small keyspace KEYS at this library size.
- **Pipelined `build_stat_hashes` prefetch (B.5)** — one pipelined HMGET per archive for `tags`/`title`/`isnew` instead of 4× sequential HGETs per archive. ~40k round-trips collapse to one on a 10k-archive library.
- **Narrow `get_archive_json` HMGET** — search-row data fetch pulls only the 11 fields that `build_json` actually serializes instead of HGETALL, avoiding the Storable-frozen `pagefiles` blob and other heavyweight fields in the payload.
- **Pipelined callback arg fix** — every `hget`/`hmget` pipelined callback in the codebase (Shinobu, Backup, Stats, Minion dup-finder) was reading `$_[1]` (the error slot) instead of `$_[0]` (the reply), a latent bug inherited from A.8. Caused `LRR_TITLES` / `LRR_TAG_INDEX_NAMES` to stay empty after `build_stat_hashes` and spurious "arcsize mismatch" reconciles at every Shinobu boot. Fixed in-place; the Perl Redis module's pipelined callback signature is `($reply, $error)`, not `($self, $reply)`.

### Server reliability

- **filesystem-aware Shinobu file watcher** — detects inode-number changes after a `filesystem receive` / dataset-swap and re-creates the watcher instead of silently losing events.
- **Non-blocking Shinobu events** — create/modify bursts are coalesced with a Redis lease and queued to an idempotent Minion ingest task, so file-stability polling, hashing, thumbnails, and auto-plugins no longer freeze the watcher loop.
- **Undef handling** hardened in search and Shinobu paths to avoid log spam on edge-case archives.
- **Edit route hardening** redirects `/edit` requests without an archive ID before touching Redis, avoiding a protocol-error 500 during smoke checks.
- **Unicode upload filename lock fix** encodes Redis lock keys before digesting/storing them, so API and Web uploads with non-ASCII filenames no longer fail during lock-token generation.
- **Large API upload checksum streaming** validates optional `/archives/upload` SHA1 checksums from the upload asset in chunks instead of slurping the whole file, allowing archives larger than 2 GiB to keep checksum verification enabled.

### Themes

- New **Catppuccin Mocha** and true-black **Catppuccin OLED** themes.

### Plugins

- New metadata plugin that parses sidecar `info.txt` files bundled with archives (distinct format from upstream's `EHDLInfo` plugin). Archives without the info.txt log at INFO and return empty (silent skip) instead of raising an ERROR — on a library with mixed sources, Auto-Plugin would otherwise flood the log.

### i18n

- Korean translations for new reader settings (Image Quality, Auto Fullscreen).
- Translation template entries propagated across all locale `.po` files.
- Upstream AVIF/JPEG XL thumbnail-format config strings are present in all locale templates; Korean translations were added with the 2026-06-23 upstream sync to avoid Maketext startup noise.

### Docs / Ops

- [`AGENTS.md`](AGENTS.md) documents the architecture, build, plugin contract, and code style for AI agents working in this repo.
- [`docs/local-features/`](docs/local-features/README.md) records current fork-only feature baselines for future upstream merges.
- [`docs/performance-optimization-research-2026-06-29.md`](docs/performance-optimization-research-2026-06-29.md) catalogs verified, HEAD-checked performance opportunities across the crop pipeline, Redis/connection layer, WebUI viewer, and caching (Korean HTML companion: [`docs/performance-optimization-research-2026-06-29.ko.html`](docs/performance-optimization-research-2026-06-29.ko.html)).
- [`docs/superpowers/plans/2026-06-29-performance-optimization.md`](docs/superpowers/plans/2026-06-29-performance-optimization.md) records the executed plan status: goal, phase-by-phase implementation resolution, verification metrics, and gated follow-ups (Korean HTML companion: [`docs/superpowers/plans/2026-06-29-performance-optimization.ko.html`](docs/superpowers/plans/2026-06-29-performance-optimization.ko.html)).
- [`docs/performance-optimization-implementation-2026-06-29.md`](docs/performance-optimization-implementation-2026-06-29.md) records the optimization execution passes: the initial 8 Tier 1 changes shipped to deployment target, post-review fixes, CACHE-1, CROP-1, REDIS-1, FE-4 deployment, live verification evidence, and the remaining gated crop items (Korean HTML companion: [`docs/performance-optimization-implementation-2026-06-29.ko.html`](docs/performance-optimization-implementation-2026-06-29.ko.html)).
- [`docs/deferred-performance-opportunities-2026-06-29.md`](docs/deferred-performance-opportunities-2026-06-29.md) summarizes the remaining deferred optimization opportunities, their dependencies, expected benefits, and crop-policy gates (Korean HTML companion: [`docs/deferred-performance-opportunities-2026-06-29.ko.html`](docs/deferred-performance-opportunities-2026-06-29.ko.html)).
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) documents the three-tier deployment procedure to the production instance (hot code-swap, compose edit, image rebuild) with pre-flight, verification, and rollback steps.
- Upstream sync 2026-06-23: merged upstream `dev` through `064e5413`, adopting the latest XSS hardening, DOMPurify 3.4.11, Valkey/Docker build updates, and `JSON::Validator` 5.19 while preserving fork reader crop/spreadstart, `/duplicates_custom`, grid-selection, and thumbnail-format locale contracts. Merge evidence and Korean HTML report: [`docs/upstream-merge-report-2026-06-23.md`](docs/upstream-merge-report-2026-06-23.md).
- Upstream sync 2026-06-09: merged upstream `dev` through `bebac1aa`, adopting path-based JS cache busting, the extracted index context-menu module, Tankoubon progress/API fixes, log-rotation fallback handling, and build dependency updates while preserving fork reader and duplicate-detection contracts.

---

## Upstream Features

For the full upstream feature list, screenshots, OPDS catalog, plugin system overview, and client API, see the [official LANraragi repository](https://github.com/Difegue/LANraragi) and [LANraragi documentation](https://sugoi.gitbook.io/lanraragi/).

## License

    MIT License

    Copyright (c) 2018 Difegue
    Copyright (c) Contributors to the LANraragi project

    Licensed under the MIT License. See COPYING for the full license text.
