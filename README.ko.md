# 커스터마이즈된 LANraragi

filesystem 기반 자가 호스팅 홈 라이브러리를 대상으로 reader, theme, reliability 개선을 유지하는 [LANraragi](https://github.com/Difegue/LANraragi) 개인 포크임.

이 포크는 사람의 지시에 따라 AI 코딩 에이전트가 유지보수함. 변경사항은 AI 생성 코드이므로 upstream 프로젝트에 pull request로 제출하지 않음. 공식 LANraragi upstream 업데이트는 주기적으로 병합함.

English version: [`README.md`](README.md).

---

## 패치 노트 (upstream 대비)

현재 merge-preservation 기준 문서는 [`docs/local-features/`](docs/local-features/README.md)에 있음. upstream sync 중 fork-only 구현 세부사항, route, Redis key, verification command 보존을 위해 해당 문서 우선 확인 필요.

### Reader

- **Auto-fullscreen**: archive open 후 첫 reading click/tap에서 fullscreen 진입, reader 종료 시 정상 해제 기능임. 구형 browser 대응을 위해 `fscreen` polyfill 사용함.
- **Image quality**: reader settings에 image quality 선택지 노출 및 mobile toggle 동작 구현임.
- **Fit-height fullscreen fix**: fullscreen 진입/해제 시 height 재계산으로 stale layout 방지함.
- **Double-page rendering**: page transition 중 double-page flicker 제거함.
- **Adaptive offset**: cover와 wide page는 항상 single 표시, archive별 server-detected `Pair 2-3` / `Pair 3-4` hint 저장, reader option은 on/off 단순화함.
- **Reader Delete key**: `Delete` 키가 표준 archive/tankoubon deletion confirmation modal을 열고, confirm 후 library로 복귀함.
- **Header hidden reader layout**: hidden-header mode에서 infinite-scroll과 동일한 minimal chrome 사용. 일반 paginated rendering, double-page mode, stamps, tap/keyboard navigation은 유지함. Bottom utility link를 숨기고 image viewport를 full-height no-scroll로 사용함. Mouse wheel up/down은 fullscreen과 동일하게 page navigation으로 동작함. Side utility icon은 vertical stack임.
- **Single-page spread sliding**: double-page fullscreen/hidden-header mode에서 `Up`은 visible spread를 한 page 이전으로, `Down`은 한 page 다음으로 이동함. One-page slide 이후 일반 prev/next navigation은 direct page jump 또는 display-mode 변경 전까지 shifted double-page stride 유지함.
- **Middle-click fullscreen**: reader 어디서든 middle-click으로 fullscreen toggle 가능함. `F` key와 동일한 의미임.
- **Reading-progress migration**: 삭제된 archive/tankoubon의 stale migration toast 반복 표시 방지, local/authenticated progress 설정 확인 후 server migration 시도함.
- **Progression Tracking disabled**: reader open 시 saved progress 무시뿐 아니라 page turn 중 local/server progress write도 억제함.
- Technical baseline: [`docs/local-features/reader.md`](docs/local-features/reader.md).

#### Adaptive Offset Detection 상세

Adaptive offset은 standalone manga archive를 위한 double-page 규칙임. Cover는 항상 title cover로 single 표시함. 이후 첫 interior spread가 **Pair 2-3**에서 시작하는지 **Pair 3-4**에서 시작하는지 결정함. Wide/landscape page는 single 표시하고 spread pairing에서 제외함.

Persistent archive fields:

- `spreadstart`: reader preference. `auto`는 adaptive detection 사용, `pair2`는 adaptive offset off 및 pages 2-3부터 고정 pairing임.
- `firstspreadstart`: detector result. 값은 `2`, `4`, `UNKNOWN` 중 하나임.
- `firstspreadstart_confidence`, `firstspreadstart_reason`, `firstspreadstart_v`: detector metadata 및 algorithm version임.
- Legacy `firstpageside*` fields는 archive content 변경 시 정리 대상이나 reader 판단에는 더 이상 사용하지 않음.

Detection lifecycle:

- 새 upload와 Shinobu-discovered archive는 `detect_first_spread_start` job을 enqueue함.
- `detect_recent_first_spread_starts`는 기본적으로 모든 기존 archive를 archive file mtime 순서로 backfill함. 양수 `args=[N]` 값을 주면 명시적으로 최신 N개 archive만 처리함.
- `recent` 이름과 `detect_recent_first_page_sides`는 오래된 queued job 호환을 위한 legacy 유지임.
- 동일 ID archive content가 바뀌면 Shinobu가 기존 `firstspreadstart*`와 legacy `firstpageside*`를 지운 뒤 새 detection을 queue함.

Detection heuristic:

- Page 1 cover와 page 2 inner/title cover는 side evidence로 신뢰하지 않아 무시함.
- Page 3-10을 sample로 사용함. Decode 실패 page는 skip함. Wide page는 `width >= height * 1.20`이면 `UNKNOWN` 처리함.
- 각 sample은 `320x320` 안에 들어가도록 downscale함. 좌우 vertical edge strip을 비교함.
- Strip width는 sample width의 10%이며 최소 4 px, 최대 image width의 절반으로 clamp함.
- Edge complexity는 luminance gradient와 darkness 기반 점수임. RTL manga에서 더 낮은 complexity의 blank/gutter 쪽으로 해당 page가 left page인지 right page인지 판정함.
- Page 3 `LEFT` + page 4 `RIGHT`는 Pair 2-3 vote임. Page 3 `RIGHT` + page 4 `LEFT`는 Pair 3-4 vote임. 이후 page sample도 같은 parity rule로 첫 interior spread에 투영함.
- 최소 2개의 confident interior sample 필요함. Weak/ambiguous vote는 `UNKNOWN` 저장이며 reader는 Pair 2-3으로 fallback함.

Reader behavior:

- `public/js/mod/reader-spread.js`가 `spreadstart`, `firstspreadstart`, current page, known wide pages로 display window를 구성함.
- Navigation은 fixed `+/-2` offset이 아니라 display window 기준으로 이동함.
- `J` key는 adaptive offset을 `auto` / `pair2` 사이에서 toggle하고 `PUT /api/archives/{id}/spreadstart?value=<auto|pair2>`로 저장함.
- Hidden-header/minimal-reader chrome logic은 `public/js/mod/reader-chrome.js`와 `public/css/reader-chrome.css`로 격리함. Deployed reader 검증은 `npm run smoke:reader-chrome` 사용함.

### Library / Thumbnails

- **Catppuccin library header spacing**: hidden MOTD slot을 collapse해 quick filter button이 top menu 바로 아래에 위치함.
- **Thumbnail loading and caching**: library page request 수 감소 및 scroll 성능 개선함.
- **Image-serving pipeline hardening**: compact-table tooltip thumbnail은 hover 시에만 fetch, thumbnail-card image는 browser lazy loading 사용, single-thumbnail miss는 Redis-backed Minion job lock으로 coalesce, thumbnail response는 download가 아닌 inline cacheable image response임.
- **Library default sort**: index 기본 URL은 `sort=1&sortdir=desc`로 열려 Date column newest-first 기준임. Explicit URL sort parameter와 저장된 non-default sort 선택은 유지함.
- **Stale `arcsize` and `pagecount` recovery**: 동일 path 아래 archive가 교체된 경우 Shinobu가 cached value와 실제 file size를 reconcile함.
- **Bulk archive actions**: 기존 fork hover-checkbox / bulk-selection-banner 설계는 ES-module sync 중 upstream MSM으로 대체됨. Index page의 `Select Archives` button으로 thumbnail carousel selection panel 사용, thumbnail click 또는 right-click `Add to selection`으로 `localStorage` selection 구성, 이후 `Select page`, `Clear`, `Run Batch Operations`, `Merge into Tankoubon` 사용함. 기존 fork spec은 history only 문서임.
- **Quick filter button 수정**: library page의 category/tag filter button이 동작하지 않던 문제 수정. ES module에서 `selectedCategory` 변수가 export되지 않아 DataTables column filter에 category ID가 전달되지 않았음.
- **Mobile portrait card sizing fix**: portrait phone/tablet에서 desktop-sized card가 표시되던 문제 수정함. 모든 template에 `initial-scale=1`, `.id3 img` cap 완화, 561-900px portrait breakpoint, <=560px `min-height` override 적용함.
- **Inline library deletion refresh**: library에서 archive/tankoubon 삭제 시 search reset 또는 전체 page reload 없이 현재 DataTables page를 제자리 redraw함. Stale multi-select 상태 정리, 필요한 경우에만 carousel dirty 처리, server redraw 후 shifted-in row/card highlight 포함함.
- **Library thumbnail draw batching**: thumbnail mode card를 DataTables row 생성 중 buffer에 모은 뒤 draw마다 `#thumbs_container`에 한 번만 swap함. 반복 live DOM mutation 감소 목적임.

### Duplicates

- **Relation-aware duplicate finder**: lead-page pHash와 normalized title/source heuristic으로 duplicate, translation variant, subset, review-only pair 분류함. Suggested delete/keep side와 risk flag 포함함.
- Technical baseline: [`docs/local-features/duplicate-detection.md`](docs/local-features/duplicate-detection.md).

### Performance

Request hot path 중심의 지속적 성능 개선임. 상세 추적 문서는 [`docs/performance-audit.md`](docs/performance-audit.md), [`docs/performance-audit-v3.md`](docs/performance-audit-v3.md), [`docs/local-features/performance-reliability.md`](docs/local-features/performance-reliability.md), 현재 baseline measurement는 [`docs/performance-baseline.md`](docs/performance-baseline.md)임.

**Tier 0**:

- `is_default_password`와 `(apikey, bearer)` tuple per-worker 30s TTL cache.
- `Archive::Libarchive::Peek` hoist로 `get_filelist` inner loop 비용 감소.
- Library thumbnail 및 index tooltip에 `decoding="async"`.
- `LRR_PDF_DPI` 환경변수로 GhostScript PDF DPI 설정 가능, default 200.
- `LRR_WORKERS` 환경변수로 Mojo prefork worker count 설정 가능, default 4.

**Tier A**:

- Process-level config cache 및 config write invalidation.
- Plugin namespace lookup hash로 Auto-Plugin per-archive lookup 단축.
- Static asset `Cache-Control: public, max-age=86400` 및 static path `Set-Cookie` skip.
- Async page-size lookup (`LRR.getImgSizeAsync`)으로 sync HEAD 제거.
- Redis bulk fetch pipeline 적용.
- `/api/archives/{id}/page` private immutable cache header.
- `LRR_MCE_WORKERS` runtime knob.
- Fresh-install `archives_per_page = 30`.
- Thumbnail-job race guard 및 single thumbnail miss coalescing.
- Image serving Prometheus metrics.
- Bounded reader preload cache 및 Blob URL eviction.
- `Server.callAPI` GET inflight-promise dedup.
- `pagefiles` filelist cache 및 warm-cache reader open 단축.
- Warm-cache inline first-page `src=`.
- Generation-keyed TTL search cache.
- Tachiyomi/Mihon-compatible API hot path cache와 placeholder thumbnail response.
- Debug flag `localStorage.lrrPerf === "1"` 기반 WebUI responsiveness instrumentation. Library draw, carousel rebuild, reader page turn, overlay rendering mark와 long-task observation 포함함.
- Reader infinite-scroll lazy windowing. 모든 page image를 선생성하고 전체 load를 기다리는 대신 near-page image window와 lazy placeholder 사용함.
- Reader preload A/B switch. `localStorage.readerPreloadStrategy = "browser"`로 browser-managed image cache/preload와 default bounded Blob URL preload path 비교 가능함.
- Reader/library render containment. 반복 thumbnail surface에 `content-visibility: auto`와 intrinsic size 적용함.

**Tier B-redis**:

- `LRR_ALL_ARCHIVES`, `LRR_CATEGORIES`, `LRR_TANKS` maintained set.
- `LRR_TAG_INDEX_NAMES` lex-sorted tag index name set.
- `build_stat_hashes` pipelined prefetch.
- Narrow `get_archive_json` HMGET.
- Pipelined callback arg fix (`$_[0]` reply, `$_[1]` error).

### Server reliability

- **filesystem-aware Shinobu file watcher**: inode-number 변화 감지 후 watcher 재생성.
- Search와 Shinobu path의 undef handling 강화.
- `/edit` missing archive ID request는 Redis 접근 전 redirect 처리.

### Themes

- 새 **Catppuccin Mocha** theme 추가함.

### Plugins

- Archive sidecar `info.txt` metadata plugin 추가함. Upstream `EHDLInfo`와 다른 format임. `info.txt`가 없는 archive는 INFO skip으로 처리해 mixed source library에서 ERROR flood 방지함.

### i18n

- 새 reader settings(Image Quality, Auto Fullscreen) Korean translation 추가함.
- Translation template entry를 모든 locale `.po` 파일에 전파함.

### Docs / Ops

- [`AGENTS.md`](AGENTS.md): repo architecture, build, plugin contract, code style for AI agents 문서임.
- [`docs/local-features/`](docs/local-features/README.md): future upstream merge를 위한 fork-only feature baseline임.
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md): production instance 대상 three-tier deployment procedure 문서임.
- Upstream sync 2026-06-09: upstream `dev`를 `bebac1aa`까지 병합함. Path-based JS cache busting, extracted index context-menu module, Tankoubon progress/API fixes, log-rotation fallback handling, build dependency updates를 도입하고 fork reader 및 duplicate-detection contract 보존함.

---

## Upstream Features

전체 upstream feature list, screenshot, OPDS catalog, plugin system overview, client API는 [official LANraragi repository](https://github.com/Difegue/LANraragi)와 [LANraragi documentation](https://sugoi.gitbook.io/lanraragi/) 참고 필요.

## License

    MIT License

    Copyright (c) 2018 Difegue
    Copyright (c) Contributors to the LANraragi project

    Licensed under the MIT License. See COPYING for the full license text.
