import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("mobile batch columns include theme borders without horizontal overflow", async (t) => {
    const chrome = [process.env.CHROME_PATH, "/opt/google/chrome/chrome", "/usr/bin/google-chrome", "/usr/bin/chromium"]
        .find((path) => path && existsSync(path));
    if (!chrome) { t.skip("Chromium is required for responsive theme geometry"); return; }
    const { chromium } = await import("playwright-core");
    const browser = await chromium.launch({ executablePath: chrome, headless: true, args: ["--no-sandbox"] });
    const css = await source("public/css/lrr.css");
    try {
        for (const theme of ["g", "ex", "modern", "modern_clear", "modern_red", "catppuccin-mocha", "catppuccin-oled"]) {
            const themeCss = await source(`public/themes/${theme}.css`);
            for (const width of [320, 390]) {
                const page = await browser.newPage({ viewport: { width, height: 900 } });
                await page.setContent(`<style>${css}</style><style>${themeCss}</style><body class="batch-page" style="margin:0;padding:0">
                    <div class="ido" style="text-align:center;width:100%;box-sizing:border-box;padding:0;border:0"><div style="margin-left:auto;margin-right:auto">
                    <div class="left-column"><div class="id1 tag-options" style="width:97%;padding:4px;height:auto">
                    Batch options with a long label ${"LongPluginParameter".repeat(8)}</div></div>
                    <div class="id1 right-column" style="text-align:center;height:500px">
                    <div style="overflow-y:auto;height:100%"><ul id="archivelist" style="margin:0;padding:0;list-style:none">
                    <li><input type="checkbox"><label>${"LongUnbrokenArchiveTitle".repeat(8)}</label></li>
                    </ul></div></div></div></div></body>`);
                const geometry = await page.evaluate(() => {
                    const column = document.querySelector(".right-column").getBoundingClientRect();
                    const panels = [...document.querySelectorAll(".batch-page .id1")].map(element => element.getBoundingClientRect());
                    return { overflow: document.documentElement.scrollWidth - innerWidth, left: column.left, right: column.right,
                        outsidePanels: panels.filter(panel => panel.left < 0 || panel.right > innerWidth + 2).length };
                });
                assert.ok(geometry.overflow <= 2, `${theme} at ${width}px: document overflow ${geometry.overflow}px`);
                assert.ok(geometry.left >= 0 && geometry.right <= width + 2, `${theme} at ${width}px: column exceeds viewport`);
                assert.equal(geometry.outsidePanels, 0, `${theme} at ${width}px: batch panel exceeds viewport`);
                await page.close();
            }
        }
    } finally { await browser.close(); }
});

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
    const reader = await source("public/js/mod/reader_common.js");

    assert.match(perf, /localStorage\.lrrPerf === "1"/);
    assert.match(perf, /PerformanceObserver/);
    assert.match(perf, /longtask/);
    assert.match(indexTable, /Perf\.measure\("index\.draw"/);
    assert.match(index, /Perf\.measure\("index\.carousel"/);
    assert.match(reader, /Perf\.measure\("reader\.goToPage"/);
    assert.match(await source("public/js/mod/reader-overlay.js"), /Perf\.measure\("reader\.overlay"/);
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
    assert.match(table, /queueMicrotask\(consumeURLParameters\)/);
    assert.match(table, /if \(!dataTable \|\| typeof dataTable\.rows !== "function"\) return;/);
    assert.match(table, /currentSearch = params\.get\("q"\) \|\| ""/);
    assert.doesNotMatch(table, /decodeURIComponent\(params\.get\("q"\)\)/);
    const doSearch = table.slice(table.indexOf("export function doSearch"), table.indexOf("// #region Compact View"));
    assert.doesNotMatch(doSearch, /Index\.loadCategories\(\)/);
    assert.equal((index.match(/\.then\(\(\) => loadCategories\(\)\)/g) || []).length, 1);
});

test("reader infinite scroll creates a lazy window instead of waiting for every image", async () => {
    const reader = await source("public/js/mod/reader_common.js");

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
    const reader = await source("public/js/mod/reader_common.js");

    assert.match(css, /\.quick-thumbnail\s*\{[\s\S]*content-visibility: auto;[\s\S]*contain-intrinsic-size:/);
    assert.match(reader, /function getReaderPreloadStrategy\(\)/);
    assert.match(reader, /localStorage\.readerPreloadStrategy/);
    assert.match(reader, /preloadImageWithBrowserCache/);
    assert.match(reader, /preloadImageWithBlobUrl/);
    assert.match(reader, /createReaderImageLoader/);
    assert.match(reader, /const nextDisplayPage = getPageNavigationDestination\(1, preloadState\)/);
    assert.match(reader, /getDisplayWindow\(nextDisplayPage, \{ \.\.\.preloadState, currentPage: nextDisplayPage \}\)/);
    const overlay = await source("public/js/mod/reader-overlay.js");
    assert.match(overlay, /const OVERLAY_PAGE_WINDOW_SIZE = 60/);
    assert.match(overlay, /overlay-window-button/);
    assert.match(reader, /if \(\$\("#archivePagesOverlay"\)\.attr\("loaded"\) === "true"\) updateArchiveOverlay\(\)/);
});

test("reader wheel page navigation debounce is tuned for wired local service", async () => {
    const reader = await source("public/js/mod/reader_common.js");

    assert.match(reader, /setTimeout\(\(\) => \{ wheelDebounce = false; \}, 100\)/);
});
