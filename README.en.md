# LANraragi Nitro

**Upstream:** [Difegue/LANraragi](https://github.com/Difegue/LANraragi)

[한국어 (default)](README.md) · English ·
[Official LANraragi documentation](https://sugoi.gitbook.io/lanraragi/)

LANraragi Nitro is a feature fork that preserves LANraragi's core architecture
and plugin compatibility while extending its reader, library workflow,
duplicate review, and image pipeline. It focuses on making large archive
collections faster to browse, read, compare, and maintain.

## Feature overview

| Area | Nitro-exclusive features | Practical effect |
| --- | --- | --- |
| Reader | Adaptive double-page spreads, session-aware resume, edge tap zones, wheel/keyboard navigation, minimal fullscreen chrome | Mixed covers, wide pages, and portrait pages retain natural spreads, including after reloads. |
| Image pipeline | Optional blank-border cropping, crop cache and single-flight, libvips page-side detection, HTTP prewarming and decode readahead | Scans with large margins use more of the viewport while repeated image work and next-page waits are reduced. |
| Library | Newest-first default, quick filters, grid selection, right-click bulk actions, batched/lazy rendering, in-place deletion | Large result sets open faster and can be selected or cleaned up without full-page reloads. |
| Duplicate review | Versioned cover pHash, band index, title/source/language relation signals, focused queue, review status and event export | Review is narrowed to useful pairs with duplicate, translation, and subset context plus prior decisions. |
| Search and API | Search-result cache, metadata/file-list warmup, Tachiyomi-compatible hot path, progress migration | Repeated searches and reader entry are cheaper, while external-reader metadata and progress flows remain stable. |
| Runtime performance | Redis handle reuse, bounded page/metadata caches, pipelined metrics and OPDS fetches, optimized image serving | Repeated Redis connections, serialization, filesystem probes, and image response costs are reduced. |
| Reliability | Streamed upload checksums, archive path validation, stale async cancellation, change-aware CI gates | Large uploads use bounded memory, archive traversal is rejected, and validation scales with the changed surface. |
| UI | Catppuccin Mocha and OLED themes, responsive archive cards, compact reader controls | The library and reader remain consistent on small screens and OLED displays. |

## Reader flow

```mermaid
flowchart LR
    A["Library hover"] --> B["HTTP prewarm"]
    B --> C["Session / progress resume"]
    C --> D["Adaptive spread"]
    D --> E["Optional border crop"]
    E --> F["Decode readahead"]
    F --> G["Latest-only progress sync"]
```

Prewarming fills only the HTTP cache; it does not eagerly decode images. Once
the reader opens, upcoming spreads are decoded relative to the current display
window. Navigation generations prevent stale asynchronous work from replacing
the current page or progress value.

## Feature details

### Reader and progress

- Covers and wide pages remain single, while portrait pages form double-page
  windows using the active anchor and detected page side.
- Explicit reloads, shifted spreads, and manga reading direction preserve the
  intended navigation stride.
- Session position is separated from persistent reading progress so browser
  reload and Library-open behavior remain distinct.
- Edge taps, mouse wheel, arrows, PageUp/PageDown, WASD, page-number jumps, and
  a confirmed Delete shortcut are supported.
- Disabling progress tracking also disables implicit resume and background
  progress writes.

### Library workflow

- The index defaults to newest-first when neither URL nor saved order overrides
  it.
- Quick filters share DataTables search state and avoid duplicate searches.
- Grid selection is isolated behind the card context-menu seam, with common
  bulk actions available directly from the selection banner.
- Deletion reconciles the current grid, counts, and carousel state in place.
- Lazy thumbnails and batched card insertion reduce initial rendering work for
  large result sets.

### Duplicate review

- Versioned perceptual hashes and cover-band buckets find visually close
  candidates first.
- Page count, lead-page hashes, normalized title, language, source, and a
  quality proxy help classify duplicate, translation, and subset candidates.
- The focused queue ignores stale responses and presents pair-relative chips
  with keep/delete suggestions.
- Dismissed and review states persist, while bounded snapshots and pair features
  can be recorded and exported as review events.
- Archive members and temporary extraction paths are validated so analysis
  cannot write outside its temporary root.

### Performance and reliability

- Redis connections and archive-path lookups are reused per worker.
- Bounded caches cover page responses, metadata, file lists, and reader Blob
  URLs, with archive-scoped invalidation.
- Crop requests use single-flight behavior and safely fall back to the original
  page when cropping is unavailable or fails.
- Metrics writes and OPDS archive fetches are pipelined or batched.
- Upload checksums are streamed instead of loading whole files into memory.
- CI classifies changed files and selects proportional frontend, Perl, OpenAPI,
  browser-evidence, runtime, and build gates.

## Upstream compatibility

This fork periodically synchronizes with LANraragi's `dev` branch. Installation,
configuration, archive management, and plugin development generally follow the
upstream project. Use the
[official documentation](https://sugoi.gitbook.io/lanraragi/) for initial setup
and base LANraragi behavior.

Issues limited to Nitro features belong in this fork. Before reporting an issue
upstream, verify that it also reproduces in upstream LANraragi.

## License

LANraragi Nitro retains LANraragi's MIT license. See [COPYING](COPYING).
