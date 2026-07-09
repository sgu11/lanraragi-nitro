import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("library delete path reconciles inline without a document reload", async () => {
    const contextMenu = await source("public/js/mod/index_contextmenu.js");
    const server = await source("public/js/mod/server.js");

    assert.match(server, /callbackDelayMs\s*=\s*1500/);
    assert.match(server, /setTimeout\(callback,\s*callbackDelayMs\)/);
    assert.match(contextMenu, /function reconcileDeletedArchive\(id\)/);
    assert.match(contextMenu, /function restoreDeleting\(id\)/);
    assert.match(contextMenu, /failureCallback: \(\) => restoreDeleting\(id\)/);
    assert.match(contextMenu, /IndexTable\.reloadAfterArchiveMutation\(\)/);
    assert.match(contextMenu, /Index\.removeArchiveFromSelection\(id\)/);
    assert.match(contextMenu, /Index\.markCarouselDirty\(\)/);
    assert.doesNotMatch(contextMenu, /document\.location\.reload\(\)/);
});

test("library thumbnail view batches card insertion and exposes current search", async () => {
    const table = await source("public/js/mod/index_datatables.js");

    assert.match(table, /export function getCurrentSearch\(\)/);
    assert.match(table, /let pendingThumbnailCards = \[\]/);
    assert.match(table, /pendingThumbnailCards\.push\(LRR\.buildThumbnailDiv\(data\)\)/);
    assert.match(table, /\$\(("#thumbs_container"|'#thumbs_container')\)\.html\(pendingThumbnailCards\.join\(""\)\)/);
    assert.match(table, /export function reloadAfterArchiveMutation\(\)/);
    assert.match(table, /dataTable\.ajax\.reload\([\s\S]*false[\s\S]*\)/);
});

test("index and reader expose debug performance marks", async () => {
    const perf = await source("public/js/mod/perf.js");
    const indexTable = await source("public/js/mod/index_datatables.js");
    const index = await source("public/js/mod/index.js");
    const reader = await source("public/js/reader.js");

    assert.match(perf, /localStorage\.lrrPerf === "1"/);
    assert.match(perf, /PerformanceObserver/);
    assert.match(perf, /longtask/);
    assert.match(indexTable, /Perf\.measure\("index\.draw"/);
    assert.match(index, /Perf\.measure\("index\.carousel"/);
    assert.match(reader, /Perf\.measure\("reader\.goToPage"/);
    assert.match(reader, /Perf\.measure\("reader\.overlay"/);
});

test("carousel uses exported DataTables search state", async () => {
    const index = await source("public/js/mod/index.js");

    assert.match(index, /IndexTable\.getCurrentSearch\(\)/);
    assert.doesNotMatch(index, /IndexTable\.currentSearch/);
    assert.match(index, /encodeURIComponent\(currentSearch\)/);
});

test("index cold load applies URL state with one search and one category fetch", async () => {
    const table = await source("public/js/mod/index_datatables.js");
    const index = await source("public/js/mod/index.js");

    assert.match(table, /deferLoading: 0/);
    assert.match(table, /currentSearch = params\.get\("q"\) \|\| ""/);
    assert.doesNotMatch(table, /decodeURIComponent\(params\.get\("q"\)\)/);
    const doSearch = table.slice(table.indexOf("export function doSearch"), table.indexOf("// #region Compact View"));
    assert.doesNotMatch(doSearch, /Index\.loadCategories\(\)/);
    assert.equal((index.match(/\.then\(\(\) => loadCategories\(\)\)/g) || []).length, 1);
});

test("reader infinite scroll creates a lazy window instead of waiting for every image", async () => {
    const reader = await source("public/js/reader.js");

    assert.match(reader, /const INFINITE_SCROLL_WINDOW_RADIUS/);
    assert.match(reader, /function materializeInfiniteScrollImage/);
    assert.match(reader, /data-src/);
    assert.match(reader, /rootMargin: "1200px"/);
    assert.match(reader, /rootMargin: "-49% 0px -49% 0px"/);
    assert.match(reader, /allImagesLoaded/);
    assert.doesNotMatch(reader, /if \(loaded === images\.length\) \{[\s\S]*allImagesLoaded = true;[\s\S]*goToPage\(currentPage\);[\s\S]*\}/);
});

test("reader overlay uses render containment and reader preload has an A/B strategy switch", async () => {
    const css = await source("public/css/lrr.css");
    const reader = await source("public/js/reader.js");

    assert.match(css, /\.quick-thumbnail\s*\{[\s\S]*content-visibility: auto;[\s\S]*contain-intrinsic-size:/);
    assert.match(reader, /function getReaderPreloadStrategy\(\)/);
    assert.match(reader, /localStorage\.readerPreloadStrategy/);
    assert.match(reader, /preloadImageWithBrowserCache/);
    assert.match(reader, /preloadImageWithBlobUrl/);
    assert.match(reader, /const OVERLAY_PAGE_WINDOW_SIZE = 60/);
    assert.match(reader, /overlay-window-button/);
    assert.match(reader, /if \(\$\("#archivePagesOverlay"\)\.attr\("loaded"\) === "true"\) updateArchiveOverlay\(\)/);
});

test("reader wheel page navigation debounce is tuned for low-latency service", async () => {
    const reader = await source("public/js/reader.js");

    assert.match(reader, /setTimeout\(\(\) => \{ wheelDebounce = false; \}, 100\)/);
});
