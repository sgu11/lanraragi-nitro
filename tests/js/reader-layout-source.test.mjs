import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("reader eagerly discovers its module graph", async () => {
    const template = await source("templates/reader.html.tt2");
    const importMap = template.indexOf("[% INCLUDE common/importmap %]");
    const preloadedModules = [
        "/js/reader.js?$asset_version",
        "/js/$version/mod/reader_common.js?$asset_version",
        "/js/i18n.js?$asset_version",
        "/js/$version/mod/server.js?$asset_version",
        "/js/$version/mod/reader-progress.js?$asset_version",
        "/js/$version/mod/common.js?$asset_version",
        "/js/$version/mod/perf.js?$asset_version",
        "/js/$version/mod/reader-crop.js?$asset_version",
        "/js/$version/mod/reader-chrome.js?$asset_version",
        "/js/$version/mod/reader-nav-keys.js?$asset_version",
        "/js/$version/mod/reader-spread.js?$asset_version",
        "/js/$version/vendor/fscreen.esm.js?$asset_version",
    ];

    assert.notEqual(importMap, -1);
    for (const modulePath of preloadedModules) {
        assert.ok(template.indexOf(`rel="modulepreload" href="[% c.url_for("${modulePath}") %]"`) > importMap);
    }
});

test("library hover prefetch fully warms a bounded two-page HTTP cache window without decoding", async () => {
    const js = await source("public/js/mod/index.js");

    assert.match(js, /const READER_INTENT_DELAY_MS = 60;/);
    assert.match(js, /const READER_INTENT_PAGE_COUNT = 2;/);
    assert.match(js, /const READER_INTENT_CACHE_MAX = 3;/);
    assert.match(js, /navigator\.connection\?\.saveData/);
    assert.match(js, /fetch\(new LRR\.ApiURL\(`\/api\/archives\/\$\{archiveId\}\/files\?force=false`\)/);
    assert.match(js, /const resumePage = archiveData \? LRR\.getProgress\(archiveData\)\.progress : 0;/);
    assert.match(js, /const startPage = getReaderIntentStartIndex\(resumePage, pages\.length\);/);
    assert.match(js, /\.slice\(startPage, startPage \+ READER_INTENT_PAGE_COUNT\)/);
    assert.match(js, /function fetchReaderIntentPage\(src, priority, signal\)/);
    assert.match(js, /credentials: "same-origin",\s*priority,\s*signal,/);
    assert.match(js, /return response\.blob\(\);[\s\S]*\.then\(\(\) => undefined\);/);
    assert.doesNotMatch(js, /decodeReaderIntentImage/);
    assert.doesNotMatch(js, /image\.decode\(\)/);
    assert.match(js, /document\.addEventListener\("pointerover", scheduleReaderIntentPrefetch, \{ passive: true \}\);/);
    assert.match(js, /document\.addEventListener\("pointerout", cancelReaderIntentPrefetch, \{ passive: true \}\);/);
    assert.match(js, /controller: new AbortController\(\)/);
    assert.match(js, /signal: entry\.controller\.signal/);
    assert.match(js, /entry && !entry\.promoted && !entry\.settled/);
    assert.match(js, /entry\.controller\.abort\(\);\s*readerIntentCache\.delete\(archiveId\);/);
    assert.match(js, /function promoteReaderIntentPrefetch\(event\)/);
    assert.match(js, /prefetchReaderIntent\(anchor, \{ promoted: true \}\);/);
    assert.match(js, /document\.addEventListener\("pointerdown", promoteReaderIntentPrefetch, \{ passive: true \}\);/);
    assert.match(js, /document\.addEventListener\("focusin",/);
    assert.match(js, /initializeReaderIntentPrefetch\(\);/);
});

test("reader only fetches stamps while marker rendering is enabled", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const toggleStart = js.indexOf("function toggleStamps()");
    const toggleEnd = js.indexOf("function handleMarkerContextMenu", toggleStart);
    const updateStart = js.indexOf("function updateProgress()");
    const updateEnd = js.indexOf("function preloadImages()", updateStart);
    const toggle = js.slice(toggleStart, toggleEnd);
    const update = js.slice(updateStart, updateEnd);

    assert.match(toggle, /if \(markersVisible\) \{\s*loadStamps\(currentPage \+ 1\);/);
    assert.match(toggle, /markers = \[\];\s*renderMarkers\(\);/);
    assert.match(update, /if \(!infiniteScroll && markersVisible\) \{\s*loadStamps\(page\);/);
});

test("reader metadata ignores stale size callbacks after its display shape changes", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const start = js.indexOf("function updateMetadata()");
    const end = js.indexOf("// Update page numbers in the paginator", start);
    const updateMetadata = js.slice(start, end);

    assert.notEqual(start, -1);
    assert.notEqual(end, -1);
    assert.match(js, /let metadataRenderGeneration = 0;/);
    assert.match(updateMetadata, /metadataRenderGeneration \+= 1;\s*const renderGeneration = metadataRenderGeneration;/);
    assert.match(updateMetadata, /const metadataPage = currentPage;/);
    assert.match(updateMetadata, /const metadataSinglePage = showingSinglePage;/);
    assert.match(updateMetadata, /metadataRenderGeneration === renderGeneration/);
    assert.match(updateMetadata, /currentPage === metadataPage/);
    assert.match(updateMetadata, /showingSinglePage === metadataSinglePage/);
    assert.equal((updateMetadata.match(/isCurrentMetadataRender\(\)/g) || []).length, 2);
});

test("reader paginator uses labeled native buttons without changing navigation values", async () => {
    const template = await source("templates/reader.html.tt2");
    const paginator = template.match(/<div class="sn paginator"[\s\S]*?<\/div>\n\[% END %\]/)?.[0] || "";

    assert.match(paginator, /<div class="sn paginator" aria-label="\[% c\.lh\('Reader page navigation'\) %\]">/);
    const controls = [
        ["outermost-left", "Previous archive"],
        ["outer-left", "First page"],
        ["left", "Previous page"],
        ["right", "Next page"],
        ["outer-right", "Last page"],
        ["outermost-right", "Next archive"],
    ];
    for (const [value, label] of controls) {
        assert.match(paginator, new RegExp(`<button type="button"[^>]*value="${value}"[^>]*aria-label="\\[% c\\.lh\\('${label}'\\) %\\]"[^>]*><\\/button>`));
    }
    assert.doesNotMatch(paginator, /<a\b[^>]*page-link/);
});

test("active set-thumbnail handler prevents anchor navigation before updating the thumbnail", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const start = js.indexOf('$(document).on("click.set-thumbnail"');
    const end = js.indexOf('$(document).on("click.thumbnail"', start);
    const handler = js.slice(start, end);

    assert.notEqual(start, -1);
    assert.notEqual(end, -1);
    assert.match(handler, /\(e\) => \{\s*e\.preventDefault\(\);/);
    assert.match(handler, /Server\.callAPI\(`\/api\/(?:tankoubons|archives)\/\$\{id\}\/thumbnail\?page=\$\{pageNumber\}`/);
    assert.match(handler, /e\.stopPropagation\(\);/);
});

test("paginated reader can use minimal chrome without enabling infinite scroll", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const css = await source("public/css/reader-chrome.css");
    const baseCss = await source("public/css/lrr.css");
    const template = await source("templates/reader.html.tt2");

    assert.match(js, /from "lrr-reader-chrome";/);
    assert.match(js, /function applyReaderChromeLayout\(\) \{/);
    assert.match(js, /toggleClass\("infinite-scroll", infiniteScroll\)/);
    assert.match(js, /toggleClass\("reader-minimal-chrome", isReaderMinimalChrome\(infiniteScroll, localStorage\.hideHeader === "true"\)\)/);

    const toggleHeaderStart = js.indexOf("function toggleHeader()");
    const toggleHeaderEnd = js.indexOf("function toggleProgressTracking()", toggleHeaderStart);
    const toggleHeader = js.slice(toggleHeaderStart, toggleHeaderEnd);

    assert.notEqual(toggleHeaderStart, -1);
    assert.notEqual(toggleHeaderEnd, -1);
    assert.match(toggleHeader, /localStorage\.hideHeader = localStorage\.hideHeader !== "true";/);
    assert.match(toggleHeader, /applyReaderChromeLayout\(\);/);
    assert.doesNotMatch(toggleHeader, /\$\(("#i2"|'#i2')\)\.toggle\(\)/);

    assert.match(css, /body\.reader-minimal-chrome \.sn,/);
    assert.match(css, /body\.reader-minimal-chrome \.file-info,/);
    assert.match(css, /body\.reader-minimal-chrome \.reading-direction/);
    assert.match(css, /body\.reader-minimal-chrome #i2\s*\{/);
    assert.match(css, /body\.reader-minimal-chrome #i5,\s*body\.reader-minimal-chrome #i7\s*\{\s*display: none;\s*\}/);
    assert.match(css, /body\.reader-minimal-chrome #i4 \.absolute-options \{[\s\S]*display: flex;[\s\S]*flex-direction: column;[\s\S]*gap: 12px;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome #i4 \.absolute-options a \{[\s\S]*padding-right: 0;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\)\s*\{\s*overflow: hidden;\s*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #i3\s*\{[\s\S]*min-height: 100vh;[\s\S]*display: flex;[\s\S]*align-items: center;[\s\S]*justify-content: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) #display\s*\{[\s\S]*height: 100vh;[\s\S]*align-items: center;[\s\S]*\}/);
    assert.match(css, /body\.reader-minimal-chrome:not\(\.infinite-scroll\) \.reader-image\s*\{[\s\S]*max-height: 100vh;[\s\S]*\}/);
    assert.doesNotMatch(baseCss, /reader-minimal-chrome/);
    assert.match(baseCss, /body\.infinite-scroll #toggle-manga-mode,/);
    assert.match(baseCss, /body\.infinite-scroll #toggle-header,/);
    assert.match(baseCss, /body\.infinite-scroll #display img\s*\{[\s\S]*margin: 0 auto;[\s\S]*\}/);
    assert.match(baseCss, /\.sni img\[src=""\]\s*\{\s*display: none;\s*\}/);
    assert.doesNotMatch(baseCss, /div\.sni img\[src=""\]/);
    assert.match(template, /\/css\/reader-chrome\.css\?\$asset_version/);
    assert.match(template, /id="settingsOverlay"[\s\S]*\[% INCLUDE config %\]/);
    assert.match(js, /getFitHeightViewportPercent\(infiniteScroll, localStorage\.hideHeader === "true"\)/);
});

test("reader hides the mouse cursor after inactivity", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const css = await source("public/css/lrr.css");
    const initStart = js.search(/export (async )?function initializeAll/);
    const initEnd = js.indexOf("function initializeSettings", initStart);
    const init = js.slice(initStart, initEnd);

    assert.notEqual(initStart, -1);
    assert.notEqual(initEnd, -1);
    assert.match(js, /const READER_CURSOR_IDLE_DELAY_MS = 1000;/);
    assert.match(js, /const READER_CURSOR_WAKE_DISTANCE_PX = 50;/);
    assert.match(js, /const READER_CURSOR_WAKE_DISTANCE_SQUARED = READER_CURSOR_WAKE_DISTANCE_PX \* READER_CURSOR_WAKE_DISTANCE_PX;/);
    assert.match(js, /let readerCursorIdleTimer = null;/);
    assert.match(js, /let readerCursorLastMousePosition = null;/);
    assert.match(js, /function setReaderCursorIdle\(idle\) \{/);
    assert.match(js, /document\.body\.classList\.toggle\("reader-cursor-idle", idle\);/);
    assert.match(js, /function handleReaderMouseMove\(e\) \{/);
    assert.match(js, /if \(!hasReaderCursorWakeMovement\(e\)\) \{ return; \}/);
    assert.match(js, /return !document\.body\.classList\.contains\("reader-cursor-idle"\);/);
    assert.match(js, /window\.clearTimeout\(readerCursorIdleTimer\);/);
    assert.match(js, /readerCursorIdleTimer = window\.setTimeout\(\(\) => setReaderCursorIdle\(true\), READER_CURSOR_IDLE_DELAY_MS\);/);
    assert.match(js, /window\.addEventListener\("mousemove", handleReaderMouseMove, \{ passive: true \}\);/);
    assert.match(init, /initializeReaderCursorAutoHide\(\);/);
    assert.match(css, /body\.reader-cursor-idle #display,/);
    assert.match(css, /body\.reader-cursor-idle #display \*[\s\S]*cursor: none !important;/);
});

test("reader navigation inputs hide cursor and ws mirrors up down navigation", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const template = await source("templates/reader.html.tt2");
    const enLocale = await source("locales/template/en.po");
    const koLocale = await source("locales/template/ko.po");
    const shortcutsStart = js.indexOf("function handleShortcuts(e)");
    const shortcutsEnd = js.indexOf("function spaceScrollProcessInput", shortcutsStart);
    const shortcuts = js.slice(shortcutsStart, shortcutsEnd);
    const initStart = js.search(/export (async )?function initializeAll/);
    const initEnd = js.indexOf("$(document).on(\"click.toggle-fit-mode\"", initStart);
    const init = js.slice(initStart, initEnd);
    const wheelStart = js.indexOf("function handleWheel(e)");
    const wheelEnd = js.indexOf("function checkFiletypeSupport", wheelStart);
    const wheel = js.slice(wheelStart, wheelEnd);

    assert.notEqual(shortcutsStart, -1);
    assert.notEqual(shortcutsEnd, -1);
    assert.notEqual(initStart, -1);
    assert.notEqual(initEnd, -1);
    assert.notEqual(wheelStart, -1);
    assert.notEqual(wheelEnd, -1);
    assert.match(js, /from "lrr-reader-nav-keys"/);
    assert.match(js, /function hideReaderCursorForNavigationInput\(which\) \{[\s\S]*setReaderCursorIdle\(true\);/);
    assert.match(init, /isReaderNavKeydownSuppress\(e\.which\)/);
    assert.match(shortcuts, /case 38: \/\/ up arrow[\s\S]*case 87: \/\/ w[\s\S]*slideSpreadBySinglePage\(-1\)/);
    assert.match(shortcuts, /case 40: \/\/ down arrow[\s\S]*case 83: \/\/ s[\s\S]*slideSpreadBySinglePage\(1\)/);
    assert.doesNotMatch(shortcuts, /case 83: \/\/ s[\s\S]*addStamp\(\);/);
    assert.doesNotMatch(js, /function addStamp\(/);
    assert.match(shortcuts, /case 37: \/\/ left arrow[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*changePage\(-1, true\);/);
    assert.match(shortcuts, /case 39: \/\/ right arrow[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*changePage\(1, true\);/);
    assert.match(shortcuts, /case 33: \/\/ page up[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*e\.preventDefault\(\);[\s\S]*if \(e\.type === "keydown"\) \{ break; \}[\s\S]*changePage\(-10, true, \{ respectReadingDirection: false \}\);/);
    assert.match(shortcuts, /case 34: \/\/ page down[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*e\.preventDefault\(\);[\s\S]*if \(e\.type === "keydown"\) \{ break; \}[\s\S]*changePage\(10, true, \{ respectReadingDirection: false \}\);/);
    assert.match(shortcuts, /case 35: \/\/ end[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*e\.preventDefault\(\);[\s\S]*if \(e\.type === "keydown"\) \{ break; \}[\s\S]*changePage\("last", true, \{ respectReadingDirection: false \}\);/);
    assert.match(shortcuts, /case 36: \/\/ home[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*e\.preventDefault\(\);[\s\S]*if \(e\.type === "keydown"\) \{ break; \}[\s\S]*changePage\("first", true, \{ respectReadingDirection: false \}\);/);
    assert.match(shortcuts, /case 65: \/\/ a[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*changePage\(-1, true\);/);
    assert.match(shortcuts, /case 68: \/\/ d[\s\S]*hideReaderCursorForNavigationInput\(\);[\s\S]*changePage\(1, true\);/);
    assert.match(wheel, /hideReaderCursorForNavigationInput\(\);[\s\S]*changePage\(direction, true\);/);
    assert.match(template, /W\/S: slide spread up\/down/);
    assert.match(template, /Home\/End: jump to beginning\/end; Page Up\/Page Down: jump previous\/next 10 pages/);
    assert.doesNotMatch(template, /S: set a Stamp/);
    assert.match(enLocale, /msgid "W\/S: slide spread up\/down"\nmsgstr "W\/S: slide spread up\/down"/);
    assert.match(enLocale, /msgid "Home\/End: jump to beginning\/end; Page Up\/Page Down: jump previous\/next 10 pages"\nmsgstr "Home\/End: jump to beginning\/end; Page Up\/Page Down: jump previous\/next 10 pages"/);
    assert.match(koLocale, /msgid "W\/S: slide spread up\/down"\nmsgstr "W\/S: 스프레드를 위\/아래로 슬라이드"/);
    assert.match(koLocale, /msgid "Home\/End: jump to beginning\/end; Page Up\/Page Down: jump previous\/next 10 pages"\nmsgstr "Home\/End: 처음\/끝으로 이동; Page Up\/Page Down: 10페이지 이전\/다음으로 이동"/);

    const localeDir = new URL("../../locales/template/", import.meta.url);
    const localeFiles = (await readdir(localeDir)).filter((file) => file.endsWith(".po"));
    for (const localeFile of localeFiles) {
        const locale = await source(`locales/template/${localeFile}`);
        assert.match(locale, /msgid "W\/S: slide spread up\/down"/, `${localeFile} includes W/S reader help`);
        assert.match(
            locale,
            /msgid "Home\/End: jump to beginning\/end; Page Up\/Page Down: jump previous\/next 10 pages"/,
            `${localeFile} includes reader jump help`
        );
    }
});

test("reader chrome exposes border crop toggle instead of help button", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const cropJs = await source("public/js/mod/reader-crop.js");
    const template = await source("templates/reader.html.tt2");
    const leftOptionsStart = template.indexOf("<div class=\"absolute-options absolute-left\">");
    const leftOptionsEnd = template.indexOf("<div class=\"absolute-options absolute-right\">", leftOptionsStart);
    const leftOptions = template.slice(leftOptionsStart, leftOptionsEnd);

    assert.notEqual(leftOptionsStart, -1);
    assert.notEqual(leftOptionsEnd, -1);
    assert.match(leftOptions, /class="[^"]*toggle-settings-overlay/);
    assert.match(leftOptions, /class="[^"]*toggle-border-crop-button/);
    assert.match(leftOptions, /fa-crop-alt/);
    assert.doesNotMatch(leftOptions, /fa-crop(?!-alt)/);
    assert.doesNotMatch(leftOptions, /id="toggle-help"/);
    assert.match(js, /\$\(document\)\.on\("click\.toggle-border-crop-button", "\.toggle-border-crop-button", toggleBorderCrop\);/);

    const updateStart = js.indexOf("function updateBorderCropToggle()");
    const updateEnd = js.indexOf("function getReaderImageSource", updateStart);
    const updateBorderCropToggle = js.slice(updateStart, updateEnd);

    assert.notEqual(updateStart, -1);
    assert.notEqual(updateEnd, -1);
    assert.match(updateBorderCropToggle, /ReaderCrop\.applyBorderCropToggleState\(cropBorders\);/);
    assert.match(cropJs, /\$\(enabled \? "#border-crop-on" : "#border-crop-off"\)\.addClass\("toggled"\);/);
    assert.match(cropJs, /\$\(("\[id='toggle-border-crop-button'\]"|'\[id="toggle-border-crop-button"\]')\)[\s\S]*\.removeClass\("fa-crop fa-crop-alt"\)[\s\S]*\.addClass\(enabled \? "fa-crop" : "fa-crop-alt"\)/);
});

test("reader border crop strings have English locale fallbacks", async () => {
    const locale = await source("locales/template/en.po");

    assert.match(locale, /msgid "Blank Border Cropping"\nmsgstr "Blank Border Cropping"/);
    assert.match(locale, /msgid "Requests reader page variants with blank scan borders removed\. Press K to toggle\."\nmsgstr "Requests reader page variants with blank scan borders removed\. Press K to toggle\."/);
    assert.match(locale, /msgid "K: toggle blank border cropping"\nmsgstr "K: toggle blank border cropping"/);
});

test("hidden-header paginated reader uses fullscreen wheel page navigation unless reader options are open", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const wheelStart = js.indexOf("function handleWheel(e)");
    const wheelEnd = js.indexOf("function checkFiletypeSupport", wheelStart);
    const wheel = js.slice(wheelStart, wheelEnd);

    assert.notEqual(wheelStart, -1);
    assert.notEqual(wheelEnd, -1);
    assert.match(wheel, /if \(\$\(("#settingsOverlay"|'#settingsOverlay')\)\.is\(":visible"\)\) return;/);
    assert.match(wheel, /if \(shouldWheelNavigatePages\(\{[\s\S]*infiniteScroll,[\s\S]*fullscreen: fscreen\.inFullscreen\(\),[\s\S]*headerHidden: localStorage\.hideHeader === "true",[\s\S]*\}\) && !wheelDebounce\) \{/);
    assert.match(wheel, /e\.preventDefault\(\);/);
    assert.match(wheel, /changePage\(direction, true\);/);
});

test("paginated reader tap-zone navigation ignores interactive controls", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const navStart = js.indexOf("$(document).on(\"click\", (event) => {");
    const navEnd = js.indexOf("});", navStart);
    const nav = js.slice(navStart, navEnd);

    assert.notEqual(navStart, -1);
    assert.notEqual(navEnd, -1);
    assert.match(js, /const READER_INTERACTIVE_TARGET_SELECTOR = "\.absolute-options, button, input, select, textarea, a\[href\]";/);
    assert.match(js, /function isReaderInteractiveTarget\(target\) \{[\s\S]*target\?\.closest\?\.\(READER_INTERACTIVE_TARGET_SELECTOR\)/);
    assert.match(nav, /\|\| !pageNaviState \|\| isReaderInteractiveTarget\(event\.target\)/);
    assert.match(nav, /changePage\(-1, true\);/);
    assert.match(nav, /changePage\(1, true\);/);
});

test("reader first-click fullscreen ignores interactive controls", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const fullscreenStart = js.indexOf("function armAutoFullscreen()");
    const fullscreenEnd = js.indexOf("function initFullscreen()", fullscreenStart);
    const fullscreen = js.slice(fullscreenStart, fullscreenEnd);

    assert.notEqual(fullscreenStart, -1);
    assert.notEqual(fullscreenEnd, -1);
    assert.match(fullscreen, /isReaderInteractiveTarget\(e\.target\)/);
    assert.ok(fullscreen.indexOf("isReaderInteractiveTarget(e.target)") < fullscreen.indexOf("e.stopPropagation();"));
});

test("minimal double-spread reader uses vertical keys for single-page spread sliding", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const shortcutStart = js.indexOf("function handleShortcuts(e)");
    const shortcutEnd = js.indexOf("function handleWheel(e)", shortcutStart);
    const shortcut = js.slice(shortcutStart, shortcutEnd);
    const initStart = js.search(/export (async )?function initializeAll/);
    const initEnd = js.indexOf("export function loadContentData", initStart);
    const init = js.slice(initStart, initEnd);
    const shiftStart = js.indexOf("function shiftRequestedSpreadByPageCount(step)");
    const shiftEnd = js.indexOf("function cycleSpreadStart", shiftStart);
    const shiftRequestedSpread = js.slice(shiftStart, shiftEnd);

    assert.notEqual(shortcutStart, -1);
    assert.notEqual(shortcutEnd, -1);
    assert.notEqual(initStart, -1);
    assert.notEqual(initEnd, -1);
    assert.notEqual(shiftStart, -1);
    assert.notEqual(shiftEnd, -1);
    assert.match(js, /getSinglePageSpreadWindow,/);
    assert.match(js, /getSpreadWindowWithPageShift,/);
    assert.match(js, /function shouldSlideSpreadWithVerticalKeys\(\) \{/);
    assert.match(js, /function slideSpreadBySinglePage\(step\) \{/);
    assert.match(js, /function shiftRequestedSpreadByPageCount\(step\) \{/);
    assert.match(js, /if \(shiftRequestedSpreadByPageCount\(step\)\) \{/);
    assert.match(shiftRequestedSpread, /const numericStep = Number\(step\);[\s\S]*if \(!Number\.isFinite\(numericStep\) \|\| Math\.abs\(numericStep\) !== 1\) \{[\s\S]*return false;[\s\S]*numericStep > 0 \? stride : -stride/);
    assert.match(shortcut, /case 38: \/\/ up arrow[\s\S]*slideSpreadBySinglePage\(-1\)/);
    assert.match(shortcut, /case 40: \/\/ down arrow[\s\S]*slideSpreadBySinglePage\(1\)/);
    assert.match(init, /isReaderNavKeydownSuppress\(e\.which\)/);
});

test("confirmed vertical spread slides lazily persist human offset feedback", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const slideStart = js.indexOf("function slideSpreadBySinglePage(step)");
    const slideEnd = js.indexOf("function shiftRequestedSpreadByPageCount(step)", slideStart);
    const feedbackStart = js.indexOf("function queueFirstSpreadStartFeedback(");
    const feedbackEnd = js.indexOf("function shouldSlideSpreadWithVerticalKeys()", feedbackStart);
    const changeStart = js.indexOf("function changePage(");
    const changeEnd = js.indexOf("function retryCurrentPage", changeStart);
    const goToStart = js.indexOf("async function goToPage");
    const goToEnd = js.indexOf("function updateProgress()", goToStart);
    const slide = js.slice(slideStart, slideEnd);
    const feedback = js.slice(feedbackStart, feedbackEnd);
    const changePage = js.slice(changeStart, changeEnd);
    const goToPage = js.slice(goToStart, goToEnd);

    assert.match(js, /inferFirstSpreadStartFromDisplayWindow,/);
    assert.match(slide, /requestedDisplayWindowRecordsHumanFeedback = true;/);
    assert.match(goToPage, /humanFeedbackDisplayWindow/);
    assert.match(goToPage, /queueFirstSpreadStartFeedback\(displayWindow, humanFeedbackDisplayWindow\)/);
    assert.match(feedback, /spreadStart !== "auto"/);
    assert.match(feedback, /id\.startsWith\("TANK_"\)/);
    assert.match(feedback, /\/api\/archives\/\$\{id\}\/firstspreadstart\?value=\$\{value\}/);
    assert.match(feedback, /method: "PUT"/);
    assert.match(changePage, /Math\.abs\(navigation\.step\) === 1[\s\S]*flushPendingFirstSpreadStartFeedback\(\)/);
});

test("explicit page reload restores double-spread navigation stride", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const selectStart = js.indexOf("function selectInitialPage()");
    const selectEnd = js.indexOf("function shouldApplyInitialPageScroll", selectStart);
    const selectInitialPage = js.slice(selectStart, selectEnd);

    assert.notEqual(selectStart, -1);
    assert.notEqual(selectEnd, -1);
    assert.match(selectInitialPage, /reason === "explicit-page"/);
    assert.match(selectInitialPage, /displayWindow: getSessionDisplayWindow\(initialPage\.page\),/);
    assert.match(selectInitialPage, /displayWindowStride: 2,/);
    assert.doesNotMatch(selectInitialPage, /displayWindowStride: 1,/);
});

test("border crop redraw preserves a shifted double-page spread", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const toggleStart = js.indexOf("function toggleBorderCrop()");
    const toggleEnd = js.indexOf("function toggleMobileFullscreen()", toggleStart);
    const goToStart = js.indexOf("async function goToPage");
    const goToEnd = js.indexOf("function updateProgress()", goToStart);
    const toggleBorderCrop = js.slice(toggleStart, toggleEnd);
    const goToPage = js.slice(goToStart, goToEnd);

    assert.notEqual(toggleStart, -1);
    assert.notEqual(toggleEnd, -1);
    assert.notEqual(goToStart, -1);
    assert.notEqual(goToEnd, -1);
    assert.match(toggleBorderCrop, /goToPage\(currentPage, \{ preserveDisplayWindow: true \}\);/);
    assert.match(goToPage, /preserveDisplayWindow = false/);
    assert.match(goToPage, /requestedDisplayWindow \|\| \(preserveDisplayWindow && activeDisplayWindowWasRequested \? activeDisplayWindow : null\)/);
});

test("queued reader navigation runs before stale-page readahead", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const runQueuedStart = js.indexOf("function runQueuedReaderNavigation()");
    const runQueuedEnd = js.indexOf("function markUserInteractionBeforeInitialPageScroll", runQueuedStart);
    const goToStart = js.indexOf("async function goToPage");
    const goToEnd = js.indexOf("function updateProgress()", goToStart);
    const runQueuedReaderNavigation = js.slice(runQueuedStart, runQueuedEnd);
    const goToPage = js.slice(goToStart, goToEnd);
    const queuedIndex = goToPage.indexOf("const ranQueuedNavigation = runQueuedReaderNavigation();");
    const preloadIndex = goToPage.search(/if \(!ranQueuedNavigation && !infiniteScroll\) \{\s*preloadImages\(\);\s*\}/);

    assert.notEqual(runQueuedStart, -1);
    assert.notEqual(runQueuedEnd, -1);
    assert.notEqual(goToStart, -1);
    assert.notEqual(goToEnd, -1);
    assert.match(runQueuedReaderNavigation, /return true;/);
    assert.match(runQueuedReaderNavigation, /return false;/);
    assert.notEqual(queuedIndex, -1);
    assert.notEqual(preloadIndex, -1);
    assert.ok(queuedIndex < preloadIndex, "queued navigation is consumed before readahead starts");
});

test("reader fit modes upscale cropped pages to the selected viewport or container", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const applyStart = js.indexOf("function applyContainerWidth()");
    const applyEnd = js.indexOf("function registerPreload()", applyStart);
    const applyContainerWidth = js.slice(applyStart, applyEnd);

    assert.notEqual(applyStart, -1);
    assert.notEqual(applyEnd, -1);
    assert.match(applyContainerWidth, /height: \$\{height\}vh; max-height: \$\{height\}vh; width: auto; object-fit: contain;/);
    assert.doesNotMatch(applyContainerWidth, /`max-height: \$\{height\}vh;`/);
    assert.match(applyContainerWidth, /"width: fit-content; width: -moz-fit-content; max-width: 100%; margin-left: auto; margin-right: auto"/);
    assert.match(applyContainerWidth, /`width: \$\{state\.containerWidth\}; max-width: 100%`/);
    assert.match(applyContainerWidth, /"width: 90%; max-width: 90%"[\s\S]*"width: 100%"/);
});

test("reader fit-container and fullscreen modes upscale small pages", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const applyStart = js.indexOf("function applyContainerWidth()");
    const applyEnd = js.indexOf("function registerPreload()", applyStart);
    const applyContainerWidth = js.slice(applyStart, applyEnd);

    assert.notEqual(applyStart, -1);
    assert.notEqual(applyEnd, -1);
    assert.doesNotMatch(applyContainerWidth, /if \(fscreen\.inFullscreen\(\)\)\s*return;/);
    assert.match(applyContainerWidth, /"width: 1200px; max-width: 100%"[\s\S]*"width: 100%"/);
});

test("reader container layout skips unchanged style and marker rewrites", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const signatureStart = js.indexOf("function getContainerLayoutSignature(");
    const signatureEnd = js.indexOf("function applyContainerWidth()", signatureStart);
    const applyStart = js.indexOf("function applyContainerWidth()");
    const applyEnd = js.indexOf("function registerPreload()", applyStart);
    const signature = js.slice(signatureStart, signatureEnd);
    const applyContainerWidth = js.slice(applyStart, applyEnd);
    const guardIndex = applyContainerWidth.indexOf("if (appliedContainerLayoutSignature === nextLayoutSignature)");
    const clearStyleIndex = applyContainerWidth.indexOf("$(\".reader-image, .sni\").attr(\"style\", \"\");");
    const storeIndex = applyContainerWidth.indexOf("appliedContainerLayoutSignature = nextLayoutSignature;");

    assert.notEqual(signatureStart, -1);
    assert.notEqual(signatureEnd, -1);
    assert.notEqual(applyStart, -1);
    assert.notEqual(applyEnd, -1);
    assert.match(js, /let appliedContainerLayoutSignature = null;/);
    assert.match(signature, /fitMode,/);
    assert.match(signature, /fullscreen,/);
    assert.match(signature, /infiniteScroll,/);
    assert.match(signature, /localStorage\.hideHeader === "true",/);
    assert.match(signature, /state\.containerWidth \|\| "",/);
    assert.match(signature, /showingSinglePage \? "single" : "double",/);
    assert.match(applyContainerWidth, /const fullscreen = fscreen\.inFullscreen\(\);/);
    assert.match(applyContainerWidth, /const nextLayoutSignature = getContainerLayoutSignature\(fullscreen\);/);
    assert.notEqual(guardIndex, -1);
    assert.notEqual(clearStyleIndex, -1);
    assert.notEqual(storeIndex, -1);
    assert.ok(guardIndex < clearStyleIndex, "unchanged layout returns before clearing inline styles");
    assert.ok(storeIndex < clearStyleIndex, "new signature is stored before style rewrites");
    assert.match(applyContainerWidth, /renderMarkers\(\);/);
});

test("explicit double-page reload revalidates restored windows after wide-page probe", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const helperStart = js.indexOf("function displayWindowHasWidePage(");
    const helperEnd = js.indexOf("async function goToPage", helperStart);
    const goToStart = js.indexOf("async function goToPage");
    const goToEnd = js.indexOf("function updateProgress()", goToStart);
    const helper = js.slice(helperStart, helperEnd);
    const goToPage = js.slice(goToStart, goToEnd);
    const probeIndex = goToPage.indexOf("await Promise.all(");
    const probedWindowIndex = goToPage.indexOf("const probedDisplayWindow = getDisplayWindow(targetPage, getSpreadState({");
    const displayWindowIndex = goToPage.indexOf("const displayWindow = displayWindowOverride && !displayWindowHasWidePage(displayWindowOverride)");

    assert.notEqual(helperStart, -1);
    assert.notEqual(helperEnd, -1);
    assert.notEqual(goToStart, -1);
    assert.notEqual(goToEnd, -1);
    assert.match(helper, /const widePages = getWidePages\(\);/);
    assert.match(helper, /for \(let page = displayWindow\.start; page <= displayWindow\.end; page \+= 1\)/);
    assert.match(helper, /if \(widePages\.has\(page\)\) \{/);
    assert.notEqual(probeIndex, -1);
    assert.notEqual(probedWindowIndex, -1);
    assert.notEqual(displayWindowIndex, -1);
    assert.ok(probeIndex < probedWindowIndex, "wide-page probe happens before recomputing the display window");
    assert.ok(probedWindowIndex < displayWindowIndex, "restored display window is checked after the probe recomputes current wide pages");
    assert.match(goToPage, /: probedDisplayWindow;/);
});
