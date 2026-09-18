import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("index title tooltip thumbnails defer network work until hover", async () => {
    const js = await source("public/js/mod/index_datatables.js");

    assert.match(js, /data-src="\$\{thumbSrc\}"/);
    assert.match(js, /lazy-tooltip-thumbnail/);
    assert.doesNotMatch(js, /style="height:300px" src="\$\{thumbSrc\}"/);
});

test("thumbnail cards mark archive images as lazy", async () => {
    const js = await source("public/js/mod/common.js");

    assert.match(js, /loading="lazy" src="\$\{thumbSrc\}"/);
});

// Scheduling, direction, pixel budgets and decode reuse are covered by the
// behavioral reader-preload-window/queue and reader-image-loader tests.

test("reader delegates decoded image placement to the shared slot owner", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const displayStart = js.indexOf("function displayDecodedImage");
    const displayEnd = js.indexOf("export async function goToPage", displayStart);
    const goStart = js.indexOf("export async function goToPage");
    const goEnd = js.indexOf("function updateProgress", goStart);
    const displayDecodedImage = js.slice(displayStart, displayEnd);
    const goToPage = js.slice(goStart, goEnd);

    assert.match(js, /import \{ replaceReaderImages \} from "lrr-reader-display"/);
    assert.match(displayDecodedImage, /replaceReaderImages\(updates,/);
    assert.match(displayDecodedImage, /selector: "#img_doublepage", image: emptyImage/);
    assert.match(goToPage, /const \[decodedImg1, decodedImg2\] = await Promise\.all/);
    assert.match(goToPage, /displayDecodedImages\(\[\s*\{ selector: "#img", image: mangaMode \? decodedImg2 : decodedImg1,[\s\S]*selector: "#img_doublepage", image: mangaMode \? decodedImg1 : decodedImg2/);
    assert.match(goToPage, /displaySingleImage\(decodedImg, imgFilename\)/);
    assert.doesNotMatch(goToPage, /\$\("#img"\)\.attr\("src", img/);
});

test("reader passes its loaded probe to the image loader and display", async () => {
    const js = await source("public/js/mod/reader_common.js");
    assert.match(js, /const probeResults = await Promise\.all/);
    assert.match(js, /const probedImages = new Map/);
    assert.match(js, /probedImages\.get\(displayStart\) \|\| await loadImage\(displayStart\)/);
    assert.match(js, /return imageLoader\.decode\(loadedImage\);/);
    assert.match(js, /return \{ src, image: displayedImage \};/);
});

test("reader crop fallback preserves cancellation and Blob ownership", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const start = js.indexOf("async function loadImage(index,");
    const end = js.indexOf("function toggleFitMode", start);
    const loader = js.slice(start, end);
    assert.match(loader, /if \(e.name === "AbortError"\) throw e;/);
    assert.match(loader, /if \(error.name === "AbortError"\) throw error;/);
    assert.match(loader, /return imageLoader\.alias\(src, fallback\);/);
    assert.match(loader, /const fallback = await preloadImageWithBlobUrl\(index, rawSrc, priority\);/);
    assert.match(loader, /displayedImage\.complete && displayedImage\.naturalWidth > 0/);
});

test("reader disabled progress tracking suppresses persistence while preserving stamps", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const start = js.indexOf("function updateProgress()");
    const end = js.indexOf("function preloadImages()");
    const updateProgress = js.slice(start, end);

    assert.notEqual(start, -1);
    assert.notEqual(end, -1);
    assert.match(js, /function updateSyncedReadingProgress\(page\)[\s\S]*if \(!ignoreProgress\) \{\s*scheduleProgressPersistence\(page\);\s*\} else \{\s*clearPendingProgressPersistence\(\);\s*\}/);
    assert.match(js, /function persistProgress\(page[\s\S]*Server\.updateServerSideProgress\(id, page[\s\S]*localStorage\.setItem\(`\$\{id\}-reader`, page\);[\s\S]*Server\.updateServerSideProgress\(id, page/);
    assert.match(updateProgress, /const displayWindow = getCurrentDisplayWindow\(\);\s*const syncedProgressPage = getSyncedReadingProgressPageForDisplayWindow\(displayWindow, pages\.length, page\);\s*commitReaderSessionPage\(page\);\s*updateSyncedReadingProgress\(syncedProgressPage\);/);
    assert.match(updateProgress, /\/\/ Load stamps[\s\S]*loadStamps\(\);/);
    assert.match(js, /const stampLayer = createReaderStamps\(\{\s*getState: \(\) => \(\{ displayWindow: pages\?\.length \? getCurrentDisplayWindow\(\) : null, mangaMode,/);
    assert.match(js, /function loadStamps\(\) \{\s*return stampLayer\.refresh\(\);/);
    assert.ok(updateProgress.indexOf("updateSyncedReadingProgress(syncedProgressPage);") < updateProgress.indexOf("// Load stamps"));
});

test("reader disabled progress tracking does not apply an implicit saved-progress jump", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const loadStart = js.indexOf("export function loadImages()");
    const loadEnd = js.indexOf("export function initializeSettings()");
    const loadImages = js.slice(loadStart, loadEnd);

    assert.notEqual(loadStart, -1);
    assert.notEqual(loadEnd, -1);
    assert.match(js, /let hasExplicitPageParameter = false;/);
    assert.match(js, /function selectInitialPage\(\)/);
    assert.match(js, /function shouldApplyInitialPageScroll\(reason\)/);
    assert.match(js, /selectReaderOpeningPage/);
    assert.match(js, /progressEnabled: !ignoreProgress,/);
    assert.match(js, /userInteractedBeforeInitialPageScroll,/);
    assert.match(loadImages, /const initialPage = selectInitialPage\(\);[\s\S]*setCurrentDisplayPage\(initialPage\.page\);/);
    assert.match(loadImages, /shouldApplyInitialPageScroll\(initialPage\.reason\)/);
    assert.doesNotMatch(loadImages, /currentPage = currentPage \|\| \(/);
});

test("reader cancels stale async page navigations before scrolling or saving progress", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const goStart = js.indexOf("async function goToPage(page");
    const goEnd = js.indexOf("function updateProgress()");
    const goToPage = js.slice(goStart, goEnd);
    const changeStart = js.indexOf("function changePage(targetPage");
    const changeEnd = js.indexOf("function handlePaginator", changeStart);
    const changePage = js.slice(changeStart, changeEnd);
    const targetStart = goToPage.indexOf("const targetPage");
    const asyncBranchStart = goToPage.indexOf("if (infiniteScroll)");
    const beforeAsyncBranch = goToPage.slice(targetStart, asyncBranchStart);

    assert.notEqual(goStart, -1);
    assert.notEqual(goEnd, -1);
    assert.notEqual(changeStart, -1);
    assert.notEqual(changeEnd, -1);
    assert.notEqual(targetStart, -1);
    assert.notEqual(asyncBranchStart, -1);
    assert.match(js, /let readerCursor = createReaderCursor\(0\);/);
    assert.match(js, /function isCurrentNavigation\(navigationId\)/);
    assert.match(goToPage, /const navigation = beginReaderNavigation\(readerCursor, page, maxPage\);\s*const navigationId = navigation\.token;/);
    assert.doesNotMatch(beforeAsyncBranch, /currentPage = targetPage;/);
    assert.match(goToPage, /const targetPage = navigation\.page;/);
    assert.match(goToPage, /commitCurrentNavigation\(navigationId, targetPage\)/);
    assert.match(goToPage, /materializeInfiniteScrollWindow\(targetPage\);/);
    assert.match(goToPage, /\$\("#display img"\)\.get\(targetPage\)\.scrollIntoView\(\{ block: "nearest" \}\);/);
    assert.match(goToPage, /if \(!isCurrentNavigation\(navigationId\)\) \{ return; \}/);
    assert.ok(goToPage.lastIndexOf("if (!isCurrentNavigation(navigationId)) { return; }") < goToPage.indexOf("updateProgress();"));
    assert.ok(goToPage.indexOf("updateProgress();") < goToPage.indexOf("const ranQueuedNavigation = runQueuedReaderNavigation();"));
    assert.match(goToPage, /catch \(error\)[\s\S]*cancelReaderNavigation\(readerCursor\);/);
    assert.match(goToPage, /#reader-load-error/);
    assert.match(goToPage, /\$\("#i3"\)\.attr\("aria-busy", "true"\);[\s\S]*const loadingTimer = setTimeout/);
    assert.match(goToPage, /if \(isCurrentNavigation\(navigationId\)\) \$\("#i3"\)\.addClass\("loading"\);[\s\S]*500/);
    assert.match(goToPage, /finally \{\s*clearTimeout\(loadingTimer\);/);
    assert.doesNotMatch(goToPage, /\$\("#i3"\)\.addClass\("loading"\)\.attr\("aria-busy", "true"\)/);
    assert.match(js, /\$\("#reader-load-retry"\)\.on\("click\.retry-reader-page", \(event\) => \{/);
    assert.match(js, /event\.preventDefault\(\);\s*event\.stopPropagation\(\);\s*const retryPage/);
    assert.match(changePage, /resolveReaderNavigationInput\(targetPage, maxPage,[\s\S]*isReaderNavigationPending\(readerCursor\)[\s\S]*queueReaderNavigationStep\(readerCursor, navigation\.step, \{ resetAuto \}\);[\s\S]*return;/);
    assert.match(js, /changePage\(queued\.step, queued\.resetAuto, \{ respectReadingDirection: false \}\);/);
});

test("reader progress persistence is latest-only and bypassed when tracking is disabled", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const updateStart = js.indexOf("function updateProgress()");
    const updateEnd = js.indexOf("function preloadImages()");
    const updateProgress = js.slice(updateStart, updateEnd);

    assert.notEqual(updateStart, -1);
    assert.notEqual(updateEnd, -1);
    assert.match(js, /const PROGRESS_PERSISTENCE_DELAY_MS = 200;/);
    assert.match(js, /function scheduleProgressPersistence\(page\)/);
    assert.match(js, /function flushProgressPersistence/);
    assert.match(js, /if \(ignoreProgress\) \{[\s\S]*clearPendingProgressPersistence\(\);[\s\S]*return;[\s\S]*\}/);
    assert.match(js, /pendingProgressPage = page;/);
    assert.match(js, /progressPersistenceTimer = setTimeout\(flushProgressPersistence, PROGRESS_PERSISTENCE_DELAY_MS\);/);
    assert.match(js, /function updateSyncedReadingProgress\(page\)[\s\S]*scheduleProgressPersistence\(page\);/);
    assert.match(updateProgress, /const displayWindow = getCurrentDisplayWindow\(\);/);
    assert.match(updateProgress, /const syncedProgressPage = getSyncedReadingProgressPageForDisplayWindow\(displayWindow, pages\.length, page\);/);
    assert.match(updateProgress, /updateSyncedReadingProgress\(syncedProgressPage\);/);
    assert.match(js, /function persistProgress\(page[\s\S]*if \(page === 0\) \{[\s\S]*localStorage\.removeItem\(`\$\{id\}-reader`\);[\s\S]*localStorage\.removeItem\(getProgressDisplayWindowKey\(\)\);[\s\S]*\}[\s\S]*if \(state\.authenticateProgress/);
});

test("server progress writes share an archive queue and retain keepalive on lock retries", async () => {
    const server = await source("public/js/mod/server.js");
    const queue = await source("public/js/mod/reader-progress.js");

    assert.match(server, /createProgressWriteQueue/);
    assert.match(server, /progressWriteQueue\.enqueue\(id, currentPage, \{ endpoint, keepalive \}\)/);
    assert.match(server, /if \(code === 423\) \{[\s\S]*throw new Error\(I18N\.GenericReponseError\);/);
    assert.match(queue, /retryCount = DEFAULT_PROGRESS_RETRY_COUNT/);
    assert.match(queue, /if \(result\?\.code !== 423\)/);
    assert.match(queue, /if \(retries >= maxRetries\)/);
    assert.match(queue, /keepalive: request\.keepalive/);
});

test("reader session page survives reload independent of progress persistence", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const updateStart = js.indexOf("function updateProgress()");
    const updateEnd = js.indexOf("function preloadImages()");
    const updateProgress = js.slice(updateStart, updateEnd);
    const fullScreenStart = js.indexOf("function handleFullScreen");
    const fullScreenEnd = js.indexOf("function getCurrentChapter", fullScreenStart);
    const handleFullScreen = js.slice(fullScreenStart, fullScreenEnd);

    assert.notEqual(updateStart, -1);
    assert.notEqual(updateEnd, -1);
    assert.notEqual(fullScreenStart, -1);
    assert.notEqual(fullScreenEnd, -1);
    assert.match(js, /function replaceReaderSessionPage\(page\)/);
    assert.match(js, /function commitReaderSessionPage\(page\)[\s\S]*replaceReaderSessionPage\(page\);/);
    assert.match(js, /window\.history\.replaceState\(null, "", url\);/);
    assert.match(updateProgress, /const page = currentPage \+ 1;[\s\S]*const displayWindow = getCurrentDisplayWindow\(\);[\s\S]*commitReaderSessionPage\(page\);[\s\S]*updateSyncedReadingProgress\(syncedProgressPage\);/);
    assert.match(handleFullScreen, /requestAnimationFrame\(\(\) => \{[\s\S]*syncInfiniteScrollCurrentPageFromViewport\(\);[\s\S]*replaceReaderSessionPage\(currentPage \+ 1\);[\s\S]*\}\);/);
});

test("reader explicit session page preserves shifted double-page window", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const selectStart = js.indexOf("function selectInitialPage()");
    const selectEnd = js.indexOf("function shouldApplyInitialPageScroll", selectStart);
    const selectInitialPage = js.slice(selectStart, selectEnd);
    const loadStart = js.indexOf("export function loadImages()");
    const loadEnd = js.indexOf("export function initializeSettings()", loadStart);
    const loadImages = js.slice(loadStart, loadEnd);
    const shiftStart = js.indexOf("function shiftRequestedSpreadByPageCount");
    const shiftEnd = js.indexOf("function cycleSpreadStart", shiftStart);
    const shiftRequestedSpreadByPageCount = js.slice(shiftStart, shiftEnd);

    assert.notEqual(selectStart, -1);
    assert.notEqual(selectEnd, -1);
    assert.notEqual(loadStart, -1);
    assert.notEqual(loadEnd, -1);
    assert.notEqual(shiftStart, -1);
    assert.notEqual(shiftEnd, -1);
    assert.match(js, /function getSessionDisplayWindow\(page\)/);
    assert.match(js, /getSpreadWindowWithPageShift\(0, getSpreadState\(\{[\s\S]*displayWindow: \{ start: page, end: page \},[\s\S]*\}\)\)/);
    assert.match(selectInitialPage, /reason: "explicit-page",[\s\S]*displayWindow: getSessionDisplayWindow\(initialPage\.page\),[\s\S]*displayWindowStride: 2,/);
    assert.match(loadImages, /requestedDisplayWindowStride = initialPage\.displayWindowStride \|\| null;/);
    assert.match(shiftRequestedSpreadByPageCount, /const numericStep = Number\(step\);[\s\S]*Math\.abs\(numericStep\) !== 1/);
    assert.match(shiftRequestedSpreadByPageCount, /const stride = activeDisplayWindowStride \|\| 2;/);
    assert.match(shiftRequestedSpreadByPageCount, /getSpreadWindowWithPageShift\(numericStep > 0 \? stride : -stride/);
    assert.match(shiftRequestedSpreadByPageCount, /requestedDisplayWindowStride = stride;/);
});

test("reader progress resume restores shifted double-page spread windows", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const selectStart = js.indexOf("function selectInitialPage()");
    const selectEnd = js.indexOf("function shouldApplyInitialPageScroll", selectStart);
    const persistStart = js.indexOf("function persistProgress");
    const persistEnd = js.indexOf("function flushProgressPersistence", persistStart);
    const loadStart = js.indexOf("export function loadImages()");
    const loadEnd = js.indexOf("export function initializeSettings()", loadStart);
    const selectInitialPage = js.slice(selectStart, selectEnd);
    const persistProgress = js.slice(persistStart, persistEnd);
    const loadImages = js.slice(loadStart, loadEnd);

    assert.notEqual(selectStart, -1);
    assert.notEqual(selectEnd, -1);
    assert.notEqual(persistStart, -1);
    assert.notEqual(persistEnd, -1);
    assert.notEqual(loadStart, -1);
    assert.notEqual(loadEnd, -1);
    assert.match(js, /function getProgressDisplayWindowKey\(\)/);
    assert.match(js, /function rememberProgressDisplayWindow\(\)/);
    assert.match(js, /function getStoredProgressDisplayWindow\(page\)/);
    assert.match(persistProgress, /rememberProgressDisplayWindow\(\);/);
    assert.match(selectInitialPage, /displayWindow: getStoredProgressDisplayWindow\(initialPage\.page\)/);
    assert.match(loadImages, /requestedDisplayWindow = initialPage\.displayWindow \|\| null;[\s\S]*goToPage\(currentPage\)/);
});

test("reader Delete key confirms archive deletion before moving to the next archive", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const shortcutStart = js.indexOf("function handleShortcuts(e)");
    const shortcutEnd = js.indexOf("function spaceScrollProcessInput(e)");
    const shortcuts = js.slice(shortcutStart, shortcutEnd);
    const helperStart = js.indexOf("function confirmDeleteArchive()");
    const helperEnd = js.indexOf("\nexport function ", helperStart + 1);
    const helper = js.slice(helperStart, helperEnd === -1 ? js.length : helperEnd);

    assert.notEqual(shortcutStart, -1);
    assert.notEqual(shortcutEnd, -1);
    assert.match(shortcuts, /case 46:\s*\/\/ delete\s+confirmDeleteArchive\(\);\s+break;/);
    assert.match(js, /\$\(document\)\.on\("click\.delete-archive", "#delete-archive", confirmDeleteArchive\);/);

    assert.notEqual(helperStart, -1);
    assert.match(helper, /LRR\.showPopUp\(\{/);
    assert.match(helper, /text: isTank \? I18N\.ConfirmTankoubonDeletion : I18N\.ConfirmArchiveDeletion,/);
    assert.match(helper, /showCancelButton: true,/);
    assert.match(helper, /focusConfirm: true,/);
    assert.match(helper, /allowEnterKey: true,/);
    assert.match(helper, /confirmButtonText: I18N\.ConfirmYes,/);
    assert.match(helper, /if \(result\.isConfirmed\) \{\s*deleteCurrentArchive\(\);\s*\}/);
    assert.match(js, /function returnToLibrary\(\) \{\s*document\.location\.href = "\.\/";\s*\}/);
    assert.match(js, /function goToNextArchiveAfterDelete\(\)/);
    assert.match(js, /Server\.deleteArchive\(id, goToNextArchiveAfterDelete,/);
    assert.match(js, /Server\.deleteTankoubon\(id, goToNextArchiveAfterDelete,/);
    assert.match(js, /callbackDelayMs: 0/);
    assert.match(js, /window\.location\.replace\(new LRR\.ApiURL\(`\/reader\?id=\$\{nextArchiveId\}`\)/);
});

test("reader blank-border crop setting maps readahead URLs and exposes k shortcut", async () => {
    const js = await source("public/js/mod/reader_common.js");
    const cropJs = await source("public/js/mod/reader-crop.js");
    const template = await source("templates/reader.html.tt2");
    const importmap = await source("templates/common/importmap.html.tt2");
    const openapi = await source("tools/openapi.yaml");
    const cropModule = await source("lib/LANraragi/Utils/ImageBorderCrop.pm");
    const [, cropAlgorithmVersion] = cropModule.match(/use constant CROP_ALGORITHM_VERSION => (\d+);/) || [];

    assert.match(js, /import \* as ReaderCrop from "lrr-reader-crop";/);
    assert.match(js, /let cropBorders = false;/);
    assert.match(js, /ReaderCrop\.readBorderCropPreference\(\)/);
    assert.match(js, /ReaderCrop\.applyBorderCropToggleState\(cropBorders\)/);
    assert.match(js, /function getReaderImageSource\(index\)/);
    assert.match(js, /ReaderCrop\.getReaderImageSource\(\{/);
    assert.match(js, /ReaderCrop\.toggleBorderCropPreference\(cropBorders\)/);

    assert.match(cropJs, /export const BORDER_CROP_CACHE_VERSION = "\d+";/);
    assert.match(cropJs, /export function readBorderCropPreference\(storage = localStorage\)/);
    assert.match(cropJs, /export function applyBorderCropToggleState\(enabled\)/);
    assert.match(cropJs, /export function shouldRequestBorderCrop\(\{ enabled, index, dimensions, isWidePage \}\)/);
    assert.match(cropJs, /if \(index === 0\) \{ return false; \}/);
    assert.match(cropJs, /export function getReaderImageSource\(\{/);
    assert.match(cropJs, /url\.searchParams\.set\("crop", "border"\)/);
    assert.ok(cropAlgorithmVersion, "crop algorithm version is declared server-side");
    assert.match(cropJs, new RegExp(`export const BORDER_CROP_CACHE_VERSION = "${cropAlgorithmVersion}";`));
    assert.match(cropJs, /url\.searchParams\.set\("cropv", BORDER_CROP_CACHE_VERSION\)/);
    assert.match(js, /const src = getReaderImageSource\(index\);/);
    assert.match(js, /const rawSrc = pages\[index\];/);
    assert.match(js, /\$\(document\)\.on\("click\.toggle-border-crop", "#toggle-border-crop input", toggleBorderCrop\);/);
    assert.match(js, /case 75:\s*\/\/ k[\s\S]*toggleBorderCrop\(\);[\s\S]*break;/);
    assert.match(importmap, /"lrr-reader-crop": "\[% c\.url_for\("\/js\/\$version\/mod\/reader-crop\.js\?\$asset_version"\) %\]"/);

    assert.match(template, /id="toggle-border-crop"/);
    assert.match(template, /id="border-crop-on"/);
    assert.match(template, /id="border-crop-off"/);
    assert.match(template, /K: toggle blank border cropping/);

    assert.match(openapi, /name: crop[\s\S]*description: >-\s*Optionally request a reader-optimized page variant with blank borders cropped/);
});
