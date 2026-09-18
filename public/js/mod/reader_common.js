/**
 * Functions to navigate in reader with the keyboard.
 * Also handles the thumbnail archive explorer.
 */
import * as Server from "lrr-server";
import * as LRR from "lrr-common";
import * as Perf from "lrr-perf";
import * as ReaderCrop from "lrr-reader-crop";
import { createReaderOverlay } from "lrr-reader-overlay";
import { applyReaderSettingsUI } from "lrr-reader-options";
import { createReaderImageLoader, createReaderPreloadQueue } from "lrr-reader-image-loader";
import { replaceReaderImages } from "lrr-reader-display";
import { createReaderStamps } from "lrr-reader-stamps";
import { buildReaderNeighborSearch } from "lrr-reader-navigation";
import I18N from "i18n";
import fscreen from "fscreen";
import {
    getFitHeightViewportPercent,
    isReaderMinimalChrome,
    shouldWheelNavigatePages,
} from "lrr-reader-chrome";
import {
    isReaderNavKeydownSuppress,
    shouldHideReaderCursorForKeyCode,
} from "lrr-reader-nav-keys";
import {
    beginReaderNavigation,
    cancelReaderNavigation,
    commitReaderNavigation,
    consumeQueuedReaderNavigationStep,
    createReaderCursor,
    getDisplayWindow,
    getDoublePageInitialProbePages,
    getPageNavigationDestination,
    getSinglePageSpreadWindow,
    getSpreadWindowWithPageShift,
    getSyncedReadingProgressPageForDisplayWindow,
    createSpreadFeedback,
    isCurrentReaderNavigation,
    isReaderNavigationPending,
    isWidePage,
    loadAdaptiveOffset,
    normalizeSpreadStartMode,
    queueReaderNavigationStep,
    resolveReaderNavigationInput,
    selectReaderOpeningPage,
    setReaderDisplayPage,
    spreadStartFlags,
} from "lrr-reader-spread";

let pageSlide = null;
let slideModule;
let slideGeneration = 0;
let slideLayout = "";
let slideEnabled = false;
let slideDuration = 200;
const reducedSlideMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let id = "";
let force = false;
let _previousPage = -1;
let currentPage = -1;
let readerCursor = createReaderCursor(0);
let currentChapter = null;
let showingSinglePage = true;
let pageThumbnails = new Set();
const MIN_PRELOADED_IMAGES = 8;
const MAX_PRELOAD_COUNT = 8;
const MAX_PREDECODED_IMAGES = Number(navigator.deviceMemory) >= 8 ? 8 : 4;
const MAX_PREDECODED_BYTES = (Number(navigator.deviceMemory) >= 8 ? 512 : 128) * 1024 * 1024;
const preloadQueue = createReaderPreloadQueue({
    concurrency: Number(navigator.deviceMemory) >= 8 ? 4 : 2,
    pixelLimit: MAX_PREDECODED_BYTES / 4,
});
let preloadDirection = 1;
let retainedDecodedSources = new Set();
const INFINITE_SCROLL_WINDOW_RADIUS = 4;
const PROGRESS_PERSISTENCE_DELAY_MS = 200;
const READER_CURSOR_IDLE_DELAY_MS = 1000;
const READER_CURSOR_WAKE_DISTANCE_PX = 200;
const READER_CURSOR_WAKE_DISTANCE_SQUARED = READER_CURSOR_WAKE_DISTANCE_PX * READER_CURSOR_WAKE_DISTANCE_PX;
let predecodeSources = new Set();
const imageLoader = createReaderImageLoader({
    // Readahead must not displace the current and previous two-page spreads.
    maxDecoded: MAX_PREDECODED_IMAGES + 4,
    maxDecodedBytes: MAX_PREDECODED_BYTES * 2,
    getRetainedSources: () => retainedDecodedSources,
    getLimit: () => {
        const factor = doublePageMode ? 2 : 1;
        const count = Math.max(0, Number(preloadCount) || 0);
        return Math.max(MIN_PRELOADED_IMAGES, (count + (count ? 1 : 0) + 1) * factor);
    },
    getProtectedSources: () => predecodeSources,
    getDisplayedSources: () => new Set(["#img", "#img_doublepage"]
        .map((selector) => $(selector).get(0)?.currentSrc).filter(Boolean).concat(pageSlide?.sources() || [])),
});
const preloadedSizes = imageLoader.sizes;
const preloadedDimensions = imageLoader.dimensions;
let metadataRenderGeneration = 0;
let archiveIndex = -1;
let archiveIds = [];
let spaceScroll = { timeout: null, animationId: null };
let imageQuality = "auto";      // fork: reader image-rendering ("auto"|"high-quality"|"smooth-sharp"|"pixelated")
let cropBorders = false;
let mobileFullscreen = true;    // fork: auto-enter fullscreen on first reading click
let spreadStart = "auto";       // fork: adaptive offset mode ("auto" on, "pair2" off)
let detectedFirstSpreadStart = undefined; // fork: server-detected first interior spread anchor ("2"|"4"|"UNKNOWN"|undefined)
let adaptiveOffsetState = null;
let sharedAdaptiveEnabled = false;
let cancelAdaptiveOffset = () => {};
let firstSpreadStart = 2;       // fork: first spread anchor (2 => pages 2-3, 4 => pages 3-4)
let activeDisplayWindow = null; // fork: current rendered spread, including one-page vertical slides
let activeDisplayWindowWasRequested = false;
let activeDisplayWindowStride = 2;
let requestedDisplayWindow = null;
let requestedDisplayWindowStride = null;
const spreadFeedback = createSpreadFeedback({
    persist: async (archiveId, value) => {
        const response = await fetch(new LRR.ApiURL(`/api/archives/${archiveId}/firstspreadstart?value=${value}`), { method: "PUT" });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
    },
    commit: (archiveId, value) => {
        if (id !== archiveId || spreadStart !== "auto") return;
        cancelAdaptiveOffset();
        detectedFirstSpreadStart = String(value);
        setSpreadStart("auto");
    },
    onError: (error) => console.warn("Failed to persist reader-confirmed spread start", error),
});
let hasExplicitPageParameter = false;
let initialPageScrollPending = false;
let userInteractedBeforeInitialPageScroll = false;
let progressPersistenceTimer = null;
let pendingProgressPage = null;
//Spacebar Scroll Config
let scrollConfig = {
    scrollDist: 75,      // Viewport % distance to scroll
    underSnap: 13,       // Distance % for snapping to edge of current image
    overSnap: 40,        // Distance % for snapping back to current image after continuous scroll
    holdDelay: 350,      // Delay time in ms before continuous scroll starts on keydown
    scrollSpeed: 22      // Speed % to scroll when spacebar is held
};
let autoNextPage = false;
let autoNextPageCountdownTaskId = undefined;
let autoNextPageCountdown = 0;
export let state = {
    trackProgressLocally: null,
    authenticateProgress: null,
    containerWidth: null,
};
let content;
let pages;
let maxPage;
let mangaMode;
let doublePageMode;
let ignoreProgress;
let infiniteScroll;
let fitMode;
let progress;
let showOverlayByDefault;
let preloadCount;
let AutoNextPageInterval;
let markerMode = false;
let markersVisible = false;
const { updateArchiveOverlay, checkStampedPages, filterStampedOverlay } = createReaderOverlay({
    getState: () => ({ currentPage, currentChapter, content, pages }),
    setCurrentChapter: (chapter) => { currentChapter = chapter; },
    getCurrentChapter, getArchiveForPage, goToPage, pageThumbnails,
});
let pageNaviState = true;
let wakeLock = null;
let readerCursorIdleTimer = null;
let readerCursorLastMousePosition = null;
let appliedContainerLayoutSignature = null;
let overlayReturnFocus = null;
const READER_INTERACTIVE_TARGET_SELECTOR = ".absolute-options, button, input, select, textarea, a[href]";

function isReaderInteractiveTarget(target) {
    return Boolean(target?.closest?.(READER_INTERACTIVE_TARGET_SELECTOR));
}

function isCurrentNavigation(navigationId) {
    return isCurrentReaderNavigation(readerCursor, navigationId);
}

function setCurrentDisplayPage(page) {
    currentPage = setReaderDisplayPage(readerCursor, page, maxPage);
    return currentPage;
}

function commitCurrentNavigation(navigationId, page) {
    if (!commitReaderNavigation(readerCursor, navigationId, page, maxPage)) {
        return false;
    }

    if (currentPage !== readerCursor.displayPage) {
        preloadDirection = Math.sign(readerCursor.displayPage - currentPage);
    }
    currentPage = readerCursor.displayPage;
    return true;
}

function runQueuedReaderNavigation() {
    const queued = consumeQueuedReaderNavigationStep(readerCursor);
    if (queued) {
        // Queued steps are resolved for reading direction when captured.
        changePage(queued.step, queued.resetAuto, { respectReadingDirection: false });
        return true;
    }
    return false;
}

function displayWindowHasWidePage(displayWindow) {
    if (!displayWindow) { return false; }
    const widePages = getWidePages();
    for (let page = displayWindow.start; page <= displayWindow.end; page += 1) {
        if (widePages.has(page)) {
            return true;
        }
    }
    return false;
}

function markUserInteractionBeforeInitialPageScroll(e) {
    if (!initialPageScrollPending || hasExplicitPageParameter) { return; }
    if (e?.target?.tagName === "INPUT") { return; }

    userInteractedBeforeInitialPageScroll = true;
    cancelReaderNavigation(readerCursor);
    setCurrentDisplayPage(0);
    if (Array.isArray(pages)) {
        goToPage(0, { resetScroll: false });
    }
}

function registerInitialPageScrollCancellation() {
    window.addEventListener("wheel", markUserInteractionBeforeInitialPageScroll, { capture: true, passive: true });
    window.addEventListener("touchstart", markUserInteractionBeforeInitialPageScroll, { capture: true, passive: true });
    window.addEventListener("pointerdown", markUserInteractionBeforeInitialPageScroll, { capture: true, passive: true });
    window.addEventListener("keydown", markUserInteractionBeforeInitialPageScroll, true);
}

function finishInitialPageScroll() {
    initialPageScrollPending = false;
}

function getProgressDisplayWindowKey() {
    return `${id}-reader-window`;
}

function rememberProgressDisplayWindow() {
    if (doublePageMode && !infiniteScroll && activeDisplayWindowWasRequested
        && activeDisplayWindow?.end > activeDisplayWindow.start) {
        localStorage.setItem(getProgressDisplayWindowKey(), JSON.stringify(activeDisplayWindow));
    } else {
        localStorage.removeItem(getProgressDisplayWindowKey());
    }
}

function getStoredProgressDisplayWindow(page) {
    if (!doublePageMode || infiniteScroll) { return null; }

    try {
        const stored = JSON.parse(localStorage.getItem(getProgressDisplayWindowKey()));
        const start = Number(stored?.start);
        const end = Number(stored?.end);
        if (start === page && Number.isInteger(start) && Number.isInteger(end)
            && end > start && start >= 0 && end <= maxPage) {
            return { start, end };
        }
    } catch {
        localStorage.removeItem(getProgressDisplayWindowKey());
    }
    return null;
}

function getSessionDisplayWindow(page) {
    if (!doublePageMode || infiniteScroll) { return null; }

    return getSpreadWindowWithPageShift(0, getSpreadState({
        currentPage: page,
        displayWindow: { start: page, end: page },
    }));
}

function selectInitialPage() {
    const initialPage = selectReaderOpeningPage({
        explicitPage: hasExplicitPageParameter ? currentPage : null,
        progressPage: progress,
        progressEnabled: !ignoreProgress,
        userInteractedBeforeInitialPageScroll,
        maxPage,
    });

    if (initialPage.reason === "explicit-page") {
        return {
            page: initialPage.page,
            reason: "explicit-page",
            displayWindow: getSessionDisplayWindow(initialPage.page),
            displayWindowStride: 2,
        };
    }

    if (initialPage.reason === "resume-progress") {
        return {
            page: initialPage.page,
            reason: "resume-progress",
            displayWindow: getStoredProgressDisplayWindow(initialPage.page),
        };
    }

    return initialPage;
}

function shouldApplyInitialPageScroll(reason) {
    if (reason === "explicit-page") { return true; }
    if (reason === "resume-progress") {
        return !ignoreProgress && !userInteractedBeforeInitialPageScroll;
    }
    return false;
}

function replaceReaderSessionPage(page) {
    const pageNumber = Number(page);
    if (!Number.isInteger(pageNumber) || pageNumber < 1) { return; }

    const url = new URL(window.location.href);
    if (url.searchParams.get("p") === String(pageNumber)) { return; }

    url.searchParams.set("p", pageNumber);
    window.history.replaceState(null, "", url);
}

function syncInfiniteScrollCurrentPageFromViewport() {
    if (!infiniteScroll) { return currentPage; }

    const images = [...document.querySelectorAll(".reader-image")];
    const midViewport = window.innerHeight / 2;
    for (let i = 0; i < images.length; i++) {
        const rect = images[i].getBoundingClientRect();
        if (rect.top <= midViewport && rect.bottom >= midViewport) {
            setCurrentDisplayPage(i);
            break;
        }
    }
    return currentPage;
}

function clearPendingProgressPersistence() {
    if (progressPersistenceTimer !== null) {
        clearTimeout(progressPersistenceTimer);
        progressPersistenceTimer = null;
    }
    pendingProgressPage = null;
}

function persistProgress(page, options = {}) {
    if (page === 0) {
        localStorage.removeItem(`${id}-reader`);
        localStorage.removeItem(getProgressDisplayWindowKey());
    } else {
        rememberProgressDisplayWindow();
    }
    if (state.authenticateProgress && LRR.isUserLogged()) {
        Server.updateServerSideProgress(id, page, options);
    } else if (state.trackProgressLocally) {
        if (page === 0) {
            localStorage.removeItem(`${id}-reader`);
        } else {
            localStorage.setItem(`${id}-reader`, page);
        }
    } else if (!state.authenticateProgress) {
        Server.updateServerSideProgress(id, page, options);
    }
}

function flushProgressPersistence(options = {}) {
    if (pendingProgressPage === null) { return; }

    const page = pendingProgressPage;
    clearPendingProgressPersistence();
    if (!ignoreProgress) {
        persistProgress(page, options);
    }
}

function scheduleProgressPersistence(page) {
    if (ignoreProgress) {
        clearPendingProgressPersistence();
        return;
    }

    pendingProgressPage = page;
    if (progressPersistenceTimer !== null) {
        clearTimeout(progressPersistenceTimer);
    }
    progressPersistenceTimer = setTimeout(flushProgressPersistence, PROGRESS_PERSISTENCE_DELAY_MS);
}

function commitReaderSessionPage(page) {
    replaceReaderSessionPage(page);
}

function updateSyncedReadingProgress(page) {
    if (!ignoreProgress) {
        scheduleProgressPersistence(page);
    } else {
        clearPendingProgressPersistence();
    }
}

function setReaderCursorIdle(idle) {
    document.body.classList.toggle("reader-cursor-idle", idle);
}

function hideReaderCursorForNavigationInput(which) {
    if (which !== undefined && !shouldHideReaderCursorForKeyCode(which)) {
        return;
    }
    setReaderCursorIdle(true);
}

function resetReaderCursorIdleTimer() {
    if (readerCursorIdleTimer !== null) {
        window.clearTimeout(readerCursorIdleTimer);
    }
    readerCursorIdleTimer = window.setTimeout(() => setReaderCursorIdle(true), READER_CURSOR_IDLE_DELAY_MS);
}

function hasReaderCursorWakeMovement(e) {
    if (!e || typeof e.clientX !== "number" || typeof e.clientY !== "number") {
        return true;
    }

    const currentPosition = {
        x: e.clientX,
        y: e.clientY,
    };

    if (readerCursorLastMousePosition === null) {
        readerCursorLastMousePosition = currentPosition;
        return !document.body.classList.contains("reader-cursor-idle");
    }

    const dx = currentPosition.x - readerCursorLastMousePosition.x;
    const dy = currentPosition.y - readerCursorLastMousePosition.y;

    if ((dx * dx + dy * dy) < READER_CURSOR_WAKE_DISTANCE_SQUARED) {
        return false;
    }

    readerCursorLastMousePosition = currentPosition;
    return true;
}

function handleReaderMouseMove(e) {
    if (!hasReaderCursorWakeMovement(e)) { return; }

    setReaderCursorIdle(false);
    resetReaderCursorIdleTimer();
}

function initializeReaderCursorAutoHide() {
    setReaderCursorIdle(false);
    resetReaderCursorIdleTimer();
    window.addEventListener("mousemove", handleReaderMouseMove, { passive: true });
    window.addEventListener("pagehide", () => {
        if (readerCursorIdleTimer !== null) {
            window.clearTimeout(readerCursorIdleTimer);
            readerCursorIdleTimer = null;
        }
        setReaderCursorIdle(false);
    }, { once: true });
}

function returnToLibrary() {
    document.location.href = "./";
}

function parseStoredArchiveIdList(key) {
    try {
        const raw = localStorage.getItem(key);
        if (!raw) { return null; }
        const parsed = JSON.parse(raw);
        return Array.isArray(parsed) ? parsed : null;
    } catch {
        return null;
    }
}

function pruneDeletedArchiveFromNavigation(deletedId) {
    ["currArchiveIds", "previousArchiveIds", "nextArchiveIds"].forEach((key) => {
        const ids = parseStoredArchiveIdList(key);
        if (ids) {
            const pruned = ids.filter((entry) => entry !== deletedId);
            if (pruned.length !== ids.length) {
                localStorage.setItem(key, JSON.stringify(pruned));
            }
        }
    });
    const inMemoryIndex = archiveIds.indexOf(deletedId);
    if (inMemoryIndex !== -1) {
        archiveIds.splice(inMemoryIndex, 1);
        if (archiveIndex > inMemoryIndex) {
            archiveIndex -= 1;
        } else if (archiveIndex === inMemoryIndex && archiveIndex >= archiveIds.length) {
            archiveIndex = archiveIds.length - 1;
        }
    }
}

function goToNextArchiveAfterDelete() {
    const deletedId = id;
    let nextArchiveId = null;

    if (archiveIds.length > 0) {
        if (archiveIndex === archiveIds.length - 1) {
            const nextIds = parseStoredArchiveIdList("nextArchiveIds");
            const currIds = parseStoredArchiveIdList("currArchiveIds");
            if (nextIds && nextIds.length > 0 && currIds) {
                nextArchiveId = nextIds[0];
                localStorage.removeItem("nextArchiveIds");
                localStorage.setItem("currArchiveIds", JSON.stringify(nextIds));
                localStorage.setItem("previousArchiveIds",
                    JSON.stringify(currIds.filter((entry) => entry !== deletedId)));
                const currentDTPage = parseInt(localStorage.getItem("currDatatablesPage") || "1", 10);
                localStorage.setItem("currDatatablesPage", currentDTPage + 1);
            }
        } else if (archiveIndex >= 0) {
            nextArchiveId = archiveIds[archiveIndex + 1];
        }
    }

    pruneDeletedArchiveFromNavigation(deletedId);

    if (nextArchiveId) {
        window.location.replace(new LRR.ApiURL(`/reader?id=${nextArchiveId}`).toString());
    } else {
        returnToLibrary();
    }
}

function deleteCurrentArchive() {
    const options = { callbackDelayMs: 0 };
    if (id.startsWith("TANK_")) Server.deleteTankoubon(id, goToNextArchiveAfterDelete, options);
    else Server.deleteArchive(id, goToNextArchiveAfterDelete, options);
}

function confirmDeleteArchive() {
    const isTank = id.startsWith("TANK_");
    LRR.closeOverlay();
    LRR.showPopUp({
        text: isTank ? I18N.ConfirmTankoubonDeletion : I18N.ConfirmArchiveDeletion,
        icon: "warning",
        showCancelButton: true,
        focusConfirm: true,
        allowEnterKey: true,
        confirmButtonText: I18N.ConfirmYes,
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (result.isConfirmed) {
            deleteCurrentArchive();
        }
    });
}

export async function initializeAll(trackProgressLocally, authenticateProgress) {
    state.trackProgressLocally = trackProgressLocally;
    state.authenticateProgress = authenticateProgress;

    Perf.initializeLongTaskObserver();
    initializeSettings();
    initFullscreen();
    applyContainerWidth();
    registerPreload();
    registerAutoNextPage();
    document.documentElement.style.scrollBehavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "auto"
        : "smooth";
    initializeReaderCursorAutoHide();

    // Bind events to DOM
    $(document).on("keyup", (e) => handleShortcuts(e));
    // Restrict keydown to keys that need browser-default suppression (see reader-nav-keys).
    $(document).on("keydown", (e) => {
        if (isReaderNavKeydownSuppress(e.which)) handleShortcuts(e);
    });
    $(document).on("wheel", handleWheel);

    $("#slide-pages").on("change", (event) => {
        slideEnabled = event.target.checked;
        localStorage.slidePages = slideEnabled;
        syncSlideSettings();
        resetPageSlide();
        void configurePageSlide();
    });
    $("#slide-duration").on("input", (event) => {
        slideDuration = Number(event.target.value);
        localStorage.slideDuration = slideDuration;
        syncSlideSettings();
        resetPageSlide();
        void configurePageSlide();
    });
    $(document).on("click.toggle-fit-mode", "#fit-mode input", toggleFitMode);
    $(document).on("click.toggle-double-mode", "#toggle-double-mode input", toggleDoublePageMode);
    $(document).on("click.toggle-manga-mode", "#toggle-manga-mode input, .reading-direction", toggleMangaMode);
    $(document).on("click.toggle-header", "#toggle-header input", toggleHeader);
    $(document).on("click.toggle-progress", "#toggle-progress input", toggleProgressTracking);
    $(document).on("click.toggle-infinite-scroll", "#toggle-infinite-scroll input", toggleInfiniteScroll);
    $(document).on("click.toggle-overlay", "#toggle-overlay input", toggleOverlayByDefault);
    $(document).on("submit.container-width", "#container-width-input", registerContainerWidth);
    $(document).on("click.container-width", "#container-width-apply", registerContainerWidth);
    $(document).on("submit.preload", "#preload-input", registerPreload);
    $(document).on("click.preload", "#preload-apply", registerPreload);
    $(document).on("click.pagination-change-pages", ".page-link", handlePaginator);
    $(document).on("submit.auto-next-page", "#auto-next-page-input", registerAutoNextPage);
    $(document).on("click.auto-next-page", "#auto-next-page-apply", registerAutoNextPage);

    $(document).on("click.close-overlay", "#overlay-shade", closeReaderOverlay);
    $(document).on("click.toggle-full-screen", ".toggle-full-screen", (e) => {
        e.preventDefault();
        e.stopPropagation();
        toggleFullScreen();
    });
    // Fork: middle-click anywhere toggles fullscreen (matches the "F or Middle-click" reader help string).
    $(document).on("auxclick.fullscreen", (e) => { if (e.button === 1) { e.preventDefault(); toggleFullScreen(); } });
    // Fork: image-quality selector + auto-fullscreen toggle + double-page spread-start.
    $("#image-quality input").on("click.image-quality", setImageQuality);
    $(document).on("click.toggle-border-crop", "#toggle-border-crop input", toggleBorderCrop);
    $(document).on("click.toggle-border-crop-button", ".toggle-border-crop-button", toggleBorderCrop);
    $(document).on("click.toggle-mobile-fullscreen", "#toggle-mobile-fullscreen input", toggleMobileFullscreen);
    $(document).on("click.toggle-spread-start", "#toggle-spread-start input", cycleSpreadStart);
    $(document).on("click.toggle-auto-next-page", ".toggle-auto-next-page", toggleAutoNextPage);
    $(document).on("click.toggle-archive-overlay", ".toggle-archive-overlay", toggleArchiveOverlay);
    $(document).on("click.toggle-settings-overlay", ".toggle-settings-overlay", toggleSettingsOverlay);
    $(document).on("click.toggle-help", "#toggle-help", toggleHelp);
    $(document).on("click.toggle-stamps", "#toggle-stamps", toggleStamps);
    $(document).on("click.toggle-bookmark", ".toggle-bookmark", toggleBookmark);
    $("#reader-load-retry").on("click.retry-reader-page", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const retryPage = Number($("#reader-load-error").attr("data-page"));
        if (Number.isInteger(retryPage)) goToPage(retryPage);
    });
    $(document).on("click.overlay-window", ".overlay-window-button", function () {
        updateArchiveOverlay(true, Number($(this).attr("data-start-page")));
    });
    $(document).on("keydown.reader-dialog", ".base-overlay", trapOverlayFocus);
    $(document).on("click.regenerate-archive-cache", "#regenerate-cache", () => {
        window.location.href = new LRR.ApiURL(`/reader?id=${id}&force_reload`);
    });
    $(document).on("click.edit-metadata", "#edit-archive", () => LRR.openInNewTab(new LRR.ApiURL(`/edit?id=${id}`)));
    $(document).on("click.delete-archive", "#delete-archive", confirmDeleteArchive);
    $(document).on("click.add-category", "#add-category", () => {
        if ($("#category").val() === "" || $(`#archive-categories a[data-id="${$("#category").val()}"]`).length !== 0) { return; }
        Server.addArchiveToCategory(id, $("#category").val());
        const categoryId = $("#category").val();
        addCategoryBadge(categoryId);

        // Turn ON bookmark icon.
        if ($("#category").val() == localStorage.bookmarkCategoryId) {
            $(".toggle-bookmark")
                .removeClass("far fa-bookmark")
                .addClass("fas fa-bookmark");
        }
    });
    $(document).on("click.remove-category", ".remove-category", (e) => {
        e.preventDefault();
        const catId = $(e.target).attr("data-id");
        Server.removeArchiveFromCategory(id, $(e.target).attr("data-id"));
        $(e.target).closest(".gt").remove();
        // Turn OFF the bookmark icon
        if (catId == localStorage.bookmarkCategoryId) {
            $(".toggle-bookmark")
                .removeClass("fas fa-bookmark")
                .addClass("far fa-bookmark");
        }
    });

    $(document).on("click.add-toc", ".add-toc", (e) => {
        const page = +$(e.target).closest("div[page]").attr("page") + 1;
        addTocSection(page);

        // Stop event propagation to avoid going to page
        e.stopPropagation();
    });
    $(document).on("click.edit-toc", ".edit-toc", () => addTocSection(currentChapter.startPage, currentChapter.name));
    $(document).on("click.remove-toc", ".remove-toc", removeTocSection);

    $(document).on("click.set-thumbnail", ".set-thumbnail", (e) => {
        e.preventDefault();
        const pageNumber = +$(e.target).closest("div[page]").attr("page") + 1;

        if (id.startsWith("TANK_")) {
            Server.callAPI(`/api/tankoubons/${id}/thumbnail?page=${pageNumber}`,
                "PUT", I18N.ReaderUpdateThumbnail(pageNumber), I18N.ReaderUpdateThumbnailError, null);
        } else {
            Server.callAPI(`/api/archives/${id}/thumbnail?page=${pageNumber}`,
                "PUT", I18N.ReaderUpdateThumbnail(pageNumber), I18N.ReaderUpdateThumbnailError, null);
        }

        // Stop event propagation to avoid going to page
        e.stopPropagation();
    });

    $(document).on("click.thumbnail", ".quick-thumbnail", (e) => {
        LRR.closeOverlay();
        const pageNumber = +$(e.target).closest("div[page]").attr("page");
        goToPage(pageNumber);
    });

    $(document).on("click.reader-image", ".reader-image", (e) => {
        if (!markerMode) return;

        $(".reader-image").css("cursor", "");
        $(".reader-image").css("z-index", 19);

        const snapshot = stampLayer.capture(e.currentTarget, e);
        if (!snapshot) return;

        LRR.showPopUp({
            title: I18N.StampName,
            input: "text",
            inputPlaceholder: I18N.StampPlaceholder,
            inputAttributes: {
                autocapitalize: "off",
            },
            showCancelButton: true,
            reverseButtons: true,
        }).then((result) => {
            $("#overlay-page").hide();
            markerMode = false;
            if (result.isConfirmed && result.value.trim() !== "") {
                stampLayer.add(snapshot, result.value);
            } else {
                renderMarkers();
            }
        });
        e.stopPropagation();
    });

    // Press esc to cancel set stamp action
    $(document).on("keydown", (e) => {
        e.stopPropagation();
        if (e.key === "Escape" && markerMode) {
            $("#overlay-page").hide();
            markerMode = false;
            renderMarkers();
            pageNaviState = true;
            $(".reader-image").css("cursor", "");
            $(".reader-image").css("z-index", 19);
        }
    });
    $(document).on("click.filter-stamped", "#filter-stamped", filterStampedOverlay);

    // Return to index, re-applying the search/page state the user came from
    $(document).on("click.return-to-index", "#return-to-index", () => {
        returnToIndex();
    });

    // Apply full-screen utility
    // F11 Fullscreen is totally another "Fullscreen", so its support is beyong consideration.
    // Small override function, always returns boolean
    fscreen.inFullscreen = () => !!fscreen.fullscreenElement;
    if (!fscreen.fullscreenEnabled) {
        // Fullscreen mode is unsupported; use attribute selector to hide all instances
        $(".toggle-full-screen").hide();
    }

    // Infer initial information from the URL
    const params = new URLSearchParams(window.location.search);
    id = params.get("id");
    force = params.get("force_reload") !== null;
    hasExplicitPageParameter = params.has("p");
    currentPage = (+params.get("p") || 1) - 1;
    readerCursor = createReaderCursor(currentPage);
    initialPageScrollPending = !hasExplicitPageParameter;
    userInteractedBeforeInitialPageScroll = false;
    registerInitialPageScrollCancellation();

    // Set up archive navigation state from the entry source (datatables vs carousel vs direct nav)
    setupArchiveNavigation().catch((error) => console.warn("Archive navigation setup failed", error));

    // Remove the "new" tag with an api call (archives only; tanks don't have an isnew flag)
    if (!id.startsWith("TANK_"))
        Server.callAPI(`/api/archives/${id}/isnew`, "DELETE", null, I18N.ReaderErrorClearingNew, null);

    // Load metadata for the requested ID and populate the page
    loadContentData().then(() => {

        document.title = content.title;
        $(".max-page").text(content.pages);

        // Regex look in tags for artist
        const artist = content.tags.match(/artist:([^,]+)(?:,|$)/i);
        if (artist) {
            const artistName = artist[1];
            const artistSearchUrl = new LRR.ApiURL(`/?sort=0&q=artist%3A${encodeURIComponent(artistName)}%24&`);
            const link = $("<a></a>")
                .attr("href", artistSearchUrl)
                .text(artistName);
            const titleContainer = $("<span></span>")
                .text(`${content.title} by `)
                .append(link);
            $("#archive-title").empty().append(titleContainer);
            $("#archive-title-overlay").empty().append(titleContainer.clone());
        } else {
            $("#archive-title").text(content.title);
            $("#archive-title-overlay").text(content.title);
        }

        $("#tagContainer").append(LRR.buildTagsDiv(content.tags));

        const ratyEl = document.querySelector(`[data-raty]`);
        if (ratyEl) {
            const rating = LRR.splitTagsByNamespace(content.tags).rating?.at(0).length;
            new Raty(ratyEl, {
                starType: `i`,
                cancelButton: true,
                cancelClass: `fas fa-trash raty-cancel`,
                cancelHint: I18N.ReaderClearRating,
                cancelPlace: `right`,
                score: rating,
                click: function(score, _element, _evt) {

                    let tags = LRR.splitTagsByNamespace(content.tags);
                    let selectedRating = score;

                    if (selectedRating === null)
                        delete tags.rating;
                    else {
                        // Create a tag with star emoji corresponding to the rating (e.g. rating:⭐⭐⭐ for a 3-star rating)
                        selectedRating = "⭐".repeat(score);
                        tags.rating = [selectedRating];
                    }

                    let tagList = LRR.buildTagList(tags);
                    if (id.startsWith("TANK_"))
                        Server.updateTagsFromTankoubon(id, tagList);
                    else
                        Server.updateTagsFromArchive(id, tagList);
                    $("#tagContainer > table").replaceWith(LRR.buildTagsDiv(tagList.join(",")));
                }
            }).init();
        }

        $("#tagContainer").append(`<div class="archive-summary"/>`);
        $(".archive-summary").text(content.summary);

        // Get the chapter for the current page (if any)
        currentChapter = getCurrentChapter();

        // Load the actual reader pages now that we have basic info
        loadImages();
    });

    // Fetch "bookmark" category ID and setup icon
    loadBookmarkStatus();
}

export function loadContentData() {

    // Initialize content object to hold metadata -- This is a recursive object that will be used to build the page overlay.
    // (For tanks, content.chapters will hold archive chapters that can themselves contain nested chapters from ToCs)
    content = {
        id: id,
        title: "",
        pages: 0,
        chapters: [],
        tags: "",
        summary: ""
    };

    const updateProgress = function(data, id) {
        // Use localStorage progress value instead of the server one if needed
        if (state.trackProgressLocally && !(state.authenticateProgress && LRR.isUserLogged())) {
            progress = localStorage.getItem(`${id}-reader`) - 1 || 0;
        } else {
            progress = data.progress - 1;
        }
    };

    // If the ID is a Tank ID (TANK_xxxx), use the Tankoubon API for metadata
    if (id.startsWith("TANK_")) {

        return fetch(new LRR.ApiURL(`/api/tankoubons/${id}/full`))
            .then(r => r.ok ? r.json() : Promise.reject(new Error(I18N.ServerInfoError)))
            .then(data => {
                const tank = data.result;
                content.title   = tank.name;
                content.tags    = tank.tags    || "";
                content.summary = tank.summary || "";

                content.chapters = [];

                // full_data contains pre-fetched metadata for every archive in order
                const fullData = tank.full_data || [];
                // Cumulative offset as we iterate through the arclist
                let pageOffset = 0;

                fullData.forEach(meta => {
                    if (!meta) return;

                    // Create archive chapter (with nested ToC chapters if present)
                    const archiveChapters = LRR.buildTankChapters(meta, pageOffset);
                    content.chapters.push(...archiveChapters);

                    pageOffset += meta.pagecount || 0;
                });

                content.pages = pageOffset;
                updateProgress(tank, id);
            })
            .catch(err => LRR.showErrorToast(I18N.ServerInfoError, err));
    }

    return Server.callAPI(`/api/archives/${id}/metadata`, "GET", null, I18N.ServerInfoError,
        (data) => {
            content.title = data.title;
            content.pages = data.pagecount;
            content.tags = data.tags;
            content.summary = data.summary;

            cancelAdaptiveOffset();
            adaptiveOffsetState = null;
            sharedAdaptiveEnabled = Boolean(data.adaptiveoffset_enabled);
            detectedFirstSpreadStart = !data.adaptiveoffset_enabled || data.firstspreadstart_reason === "user_slide"
                ? data.firstspreadstart : undefined;
            setSpreadStart(data.spreadstart || "auto"); // fork: per-archive adaptive offset mode


            updateProgress(data, id);

            if (data.toc)
                content.chapters = LRR.buildArchiveChapters(data.toc, id, data.pagecount);

            // Check and display warnings for unsupported filetypes
            checkFiletypeSupport(data.extension);
        }
    );
}

/**
 * For Tank mode: map a page number to the archive it belongs to and said archive's local page number.
 * @param {number} globalPage global page number
 * @returns {{ arcId: string, localPage: number }}
 */
export function getArchiveForPage(globalPage) {
    if (id.startsWith("TANK_")) {
        const arc = content.chapters.find(a => globalPage >= a.startPage && globalPage <= a.endPage);
        if (arc)
            return { arcId: arc.id, localPage: globalPage - arc.startPage + 1 };
    }
    return { arcId: id, localPage: globalPage };
};

/**
 * Adds a removable category flag to the categories section within archive overview.
 */
export function addCategoryBadge(categoryId) {
    const categoryName = $(`#category option[value="${categoryId}"]`).text();
    const url = new LRR.ApiURL(`/?c=${categoryId}`);
    const html = `<div class="gt" style="font-size:14px; padding:4px">
        <a href="${url}">
        <span class="label">${LRR.encodeHTML(categoryName)}</span>
        <a href="#" class="remove-category" data-id="${categoryId}"
            style="margin-left:4px; margin-right:2px">×</a>
    </a>`;
    $("#archive-categories").append(html);
}

export function removeCategoryBadge(categoryId) {
    $(`#archive-categories a.remove-category[data-id="${categoryId}"]`).closest(".gt").remove();
}

export function addTocSection(page, currentTitle = null) {

    LRR.closeOverlay();
    LRR.showPopUp({
        title: I18N.ReaderTocPrompt,
        input: "text",
        inputPlaceholder: currentTitle || I18N.UntitledChapter,
        inputAttributes: {
            autocapitalize: "off",
        },
        showCancelButton: true,
        reverseButtons: true,
    }).then((result) => {
        if (result.isConfirmed && result.value.trim() !== "") {
            const { arcId, localPage } = getArchiveForPage(page);
            const params = new URLSearchParams({ page: localPage, title: result.value });
            Server.callAPI(`/api/archives/${arcId}/toc?${params}`, "PUT", "Chapter added!", I18N.ReaderTocError,
                () => loadContentData().then(() => {
                    updateArchiveOverlay(true);
                    toggleArchiveOverlay();
                    goToPage(page);
                })
            );
        } else {
            toggleArchiveOverlay();
        }
    });
}

export function removeTocSection() {

    LRR.closeOverlay();
    LRR.showPopUp({
        text: I18N.ReaderDeleteTocPrompt,
        icon: "warning",
        showCancelButton: true,
        focusConfirm: false,
        confirmButtonText: I18N.ConfirmYes,
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (result.isConfirmed) {
            const { arcId, localPage } = getArchiveForPage(currentChapter.startPage);
            Server.callAPI(`/api/archives/${arcId}/toc?page=${localPage}`, "DELETE", "Chapter removed!", I18N.ReaderTocError,
                () => loadContentData().then(() => {
                    updateArchiveOverlay(true);
                    toggleArchiveOverlay();
                })
            );
        } else {
            toggleArchiveOverlay();
        }
    });
}

export function loadImages() {

    const onLoad = (data) => {
        pages = data;
        maxPage = pages.length - 1;
        $(".max-page").html(pages.length);

        // Choices in order for page picking:
        // * p is in parameters and is not the first page
        // * progress is tracked and is not the last page
        // * first page
        // This allows for bookmarks to trump progress
        const initialPage = selectInitialPage();
        setCurrentDisplayPage(initialPage.page);
        requestedDisplayWindow = initialPage.displayWindow || null;
        requestedDisplayWindowStride = initialPage.displayWindowStride || null;

        if (infiniteScroll) {
            initInfiniteScrollView(initialPage.reason);
            if (content.tags?.includes("webtoon")) {
                $("head").append(`
                    <style id="webtoon-css">
                        .reader-image {
                            margin-bottom: 0 !important;
                            margin-top: 0 !important;
                        }
                    </style>
                `);
            }
        } else {
            $("#img").on("load", updateMetadata);

            // Navigation tap zones (Suwayomi-style EDGE layout)
            //   +---+---+---+
            //   | P | P | P |  P: Previous
            //   +---+---+---+
            //   | P | M | P |  M: Menu
            //   +---+---+---+
            //   | P | N | P |  N: Next
            //   +---+---+---+
            $(document).on("click", (event) => {
                if ($("#overlay-shade").is(":visible") || !pageNaviState || isReaderInteractiveTarget(event.target)) return;

                const container = document.getElementById("i3");
                if (!container) return;
                const rect = container.getBoundingClientRect();
                const xPct = event.clientX / window.innerWidth * 100;
                const yPct = (event.clientY - rect.top) / rect.height * 100;
                if (yPct < 0 || yPct > 100) return;

                if (yPct < 33.33) {
                    changePage(-1, true);
                } else if (xPct < 33.33) {
                    changePage(-1, true);
                } else if (xPct > 66.66) {
                    changePage(-1, true);
                } else if (yPct < 66.66) {
                    toggleSettingsOverlay();
                } else {
                    changePage(1, true);
                }
            });

            $(".current-page").each((_i, el) => $(el).html(currentPage + 1));
            if (shouldApplyInitialPageScroll(initialPage.reason)) {
                goToPage(currentPage).finally(finishInitialPageScroll);
            } else {
                finishInitialPageScroll();
                goToPage(currentPage, { resetScroll: false });
            }
        }

        if (showOverlayByDefault) { toggleArchiveOverlay(); }

        // Resume slideshow if it was active before cross-archive navigation
        if (sessionStorage.getItem("autoNextPage") === "true") {
            sessionStorage.removeItem("autoNextPage");
            startAutoNextPage();
        }
    };

    const onFinally = () => {
        if (pages === undefined) {
            $("#img").attr("src", new LRR.ApiURL("/img/flubbed.gif").toString());
            $("#display").append(`<h2>${I18N.ReaderArchiveError}</h2>`);
        }
        generateThumbnails();
    };

    if (id.startsWith("TANK_")) {
        // For tanks: fetch pages for each archive and concatenate them
        Promise.all(
            content.chapters.map(arc =>
                fetch(new LRR.ApiURL(`/api/archives/${arc.id}/files?force=${force}`))
                    .then(r => r.ok ? r.json() : Promise.reject())
            )
        ).then(results => {
            onLoad(results.flatMap(r => r.pages));
        }).catch(() => LRR.showErrorToast(I18N.ReaderArchiveError))
            .finally(onFinally);
    }
    else {
        Server.callAPI(`/api/archives/${id}/files?force=${force}`, "GET", null, I18N.ReaderArchiveError,
            (data) => onLoad(data.pages),
        ).finally(onFinally);
    }
}

export function initializeSettings() {
    mangaMode = localStorage.mangaMode === "true";
    doublePageMode = localStorage.doublePageMode === "true";
    ignoreProgress = localStorage.ignoreProgress === "true";
    infiniteScroll = localStorage.infiniteScroll === "true";
    showOverlayByDefault = localStorage.showOverlayByDefault === "true";
    markersVisible = localStorage.markersVisible === "true";
    imageQuality = localStorage.imageQuality || "auto";
    mobileFullscreen = localStorage.mobileFullscreen !== "false";
    fitMode = ["fit-width", "fit-height"].includes(localStorage.fitMode) ? localStorage.fitMode : "fit-container";
    state.containerWidth = localStorage.containerWidth;
    cropBorders = ReaderCrop.readBorderCropPreference();
    applyReaderSettingsUI({ mangaMode, doublePageMode, ignoreProgress, infiniteScroll,
        showOverlayByDefault, markersVisible, imageQuality, mobileFullscreen,
        containerWidth: state.containerWidth });
    slideEnabled = localStorage.slidePages === "true";
    const savedDuration = Number(localStorage.slideDuration);
    slideDuration = Number.isFinite(savedDuration) && savedDuration > 0
        ? Math.max(50, Math.min(1000, Math.round(savedDuration / 25) * 25)) : 200;
    syncSlideSettings();
    applyReaderChromeLayout();
    applyImageQuality();
    updateBorderCropToggle();
}

function syncSlideSettings() {
    $("#slide-pages").prop("checked", slideEnabled);
    $("#slide-duration").val(slideDuration).prop("disabled", !slideEnabled);
    $("#slide-duration-value").text(`${slideDuration} ms`);
}

function resetPageSlide() {
    slideGeneration += 1;
    pageSlide?.dispose();
    pageSlide = null;
    slideLayout = "";
}

async function configurePageSlide() {
    if (!slideEnabled || infiniteScroll || reducedSlideMotion.matches || !pages?.length) {
        resetPageSlide();
        return;
    }
    // Page index is not a setting. Only archive identity and real layout values reset motion.
    const layout = [id, getArchiveForPage(currentPage + 1)?.arcId, mangaMode, doublePageMode,
        cropBorders, imageQuality, fitMode, fscreen.inFullscreen(), localStorage.hideHeader,
        state.containerWidth, slideDuration].join("|");
    if (pageSlide && slideLayout === layout) return;
    resetPageSlide();
    const token = slideGeneration;
    slideModule ||= await import("lrr-reader-slide");
    if (token !== slideGeneration) return;
    slideLayout = layout;
    pageSlide = slideModule.createReaderSlide({
        element: document.getElementById("display"), duration: slideDuration,
        read: () => [document.getElementById("img"), document.getElementById("img_doublepage")].filter(Boolean),
        navigate: direction => changePage(direction, true),
        loadNeighbors: async () => {
            const navigationId = readerCursor.token;
            const isCurrent = () => token === slideGeneration && isCurrentNavigation(navigationId);
            const prepareImage = (index, decode = false) => preloadQueue.schedule(async () => {
                const loaded = await loadImage(index, "low");
                if (!isCurrent()) return;
                return decode ? decodeImage(loaded) : loaded;
            }, { pixels: estimatePredecodePixels(index), isCurrent });
            const snapshot = getSpreadState();
            const requested = doublePageMode && activeDisplayWindowWasRequested
                && activeDisplayWindow?.end > activeDisplayWindow?.start ? activeDisplayWindow : null;
            const stride = activeDisplayWindowStride || 2;
            return Promise.all([-1, 1].map(async step => {
                const shifted = requested ? getSpreadWindowWithPageShift(step * stride,
                    { ...snapshot, displayWindow: requested }) : null;
                const destination = shifted?.start ?? getPageNavigationDestination(step, snapshot);
                const direction = step * (mangaMode ? -1 : 1);
                if (destination < 0 || destination > maxPage) return { direction, images: [] };
                if (doublePageMode) {
                    await Promise.all(getDoublePageInitialProbePages(destination, maxPage)
                        .filter(index => !preloadedDimensions[index]).map(index => prepareImage(index)));
                }
                if (!isCurrent()) return { direction, images: [] };
                const window = shifted && !displayWindowHasWidePage(shifted) ? shifted
                    : getDisplayWindow(destination, { ...snapshot, widePages: getWidePages(), currentPage: destination });
                const indexes = Array.from({ length: window.end - window.start + 1 }, (_, i) => window.start + i);
                const images = await Promise.all(indexes.map(index => prepareImage(index, true)));
                if (images.some(image => !image)) return { direction, images: [] };
                return { direction, images: mangaMode ? images.reverse() : images };
            }));
        },
    });
}

reducedSlideMotion.addEventListener("change", () => { resetPageSlide(); void configurePageSlide(); });

function applyReaderChromeLayout() {
    $("body").toggleClass("infinite-scroll", infiniteScroll);
    $("body").toggleClass("reader-minimal-chrome", isReaderMinimalChrome(infiniteScroll, localStorage.hideHeader === "true"));
}

// fork: apply image-rendering via an <html data-img-quality> attribute so it
// covers all current AND future .reader-image elements without hooking the render path.
function applyImageQuality() {
    document.documentElement.setAttribute("data-img-quality", imageQuality || "auto");
}

function setImageQuality() {
    const map = { "quality-auto": "auto", "quality-high": "high-quality", "quality-sharp": "smooth-sharp", "quality-pixelated": "pixelated" };
    imageQuality = map[this.id] || "auto";
    localStorage.imageQuality = imageQuality;
    $("#image-quality input").removeClass("toggled");
    $(`#${this.id}`).addClass("toggled");
    applyImageQuality();
    void configurePageSlide();
}

function updateBorderCropToggle() {
    ReaderCrop.applyBorderCropToggleState(cropBorders);
}

function getReaderImageSource(index) {
    return ReaderCrop.getReaderImageSource({
        rawSrc: pages[index],
        index,
        enabled: cropBorders,
        dimensions: preloadedDimensions[index],
        isWidePage,
    });
}

function toggleBorderCrop() {
    cropBorders = ReaderCrop.toggleBorderCropPreference(cropBorders);
    updateBorderCropToggle();
    revokePreloadedImages();

    if (!pages) { return false; }
    if (infiniteScroll) {
        window.location.reload();
        return false;
    }
    goToPage(currentPage, { preserveDisplayWindow: true });
    return false;
}

function toggleMobileFullscreen() {
    mobileFullscreen = !mobileFullscreen;
    localStorage.mobileFullscreen = mobileFullscreen;
    $("#toggle-mobile-fullscreen input").toggleClass("toggled");
}

function requestSharedAdaptiveOffset() {
    cancelAdaptiveOffset();
    if (!sharedAdaptiveEnabled || adaptiveOffsetState || spreadStart !== "auto" || !doublePageMode || infiniteScroll
        || !/^[a-f0-9]{40}$/.test(id)) return;
    const archiveId = id;
    cancelAdaptiveOffset = loadAdaptiveOffset({
        archiveId,
        request: async (signal) => {
            const response = await fetch(new LRR.ApiURL(`/api/archives/${archiveId}/adaptiveoffset`), { signal });
            if (![200, 202].includes(response.status)) throw new Error("Adaptive evidence unavailable");
            return response.json();
        },
        commit: (result) => {
            if (id !== archiveId || spreadStart !== "auto") return;
            adaptiveOffsetState = result;
            detectedFirstSpreadStart = result.first_spread_start;
            setSpreadStart("auto");
            if (currentPage >= 0 && doublePageMode && !infiniteScroll) goToPage(currentPage, { resetScroll: false });
        },
    });
}

// fork: adaptive offset control, persisted per-archive.
function setSpreadStart(value) {
    spreadStart = normalizeSpreadStartMode(value);
    if (spreadStart !== "auto") { spreadFeedback.cancel(); cancelAdaptiveOffset(); }
    ({ firstSpreadStart } = spreadStartFlags(spreadStart, detectedFirstSpreadStart));
    $("#toggle-spread-start input").removeClass("toggled");
    $(`#spread-${spreadStart}`).addClass("toggled");
    requestSharedAdaptiveOffset();
}

function getWidePages() {
    const widePages = new Set();
    Object.entries(preloadedDimensions).forEach(([page, dimensions]) => {
        if (isWidePage(dimensions)) {
            widePages.add(Number(page));
        }
    });
    return widePages;
}

function getSpreadState(overrides = {}) {
    return {
        archiveId: id,
        contentRevision: adaptiveOffsetState?.contentRevision,
        segments: spreadStart === "auto" ? adaptiveOffsetState?.segments : [],
        maxPage,
        doublePageMode,
        firstSpreadStart,
        widePages: getWidePages(),
        currentPage,
        ...overrides,
    };
}

function getCurrentDisplayWindow() {
    if (activeDisplayWindow && doublePageMode && !infiniteScroll) {
        return activeDisplayWindow;
    }
    return getDisplayWindow(currentPage, getSpreadState());
}

function shouldSlideSpreadWithVerticalKeys() {
    return doublePageMode && shouldWheelNavigatePages({
        infiniteScroll,
        fullscreen: fscreen.inFullscreen(),
        headerHidden: localStorage.hideHeader === "true",
    });
}

function slideSpreadBySinglePage(step) {
    if (!shouldSlideSpreadWithVerticalKeys()) {
        return false;
    }

    requestedDisplayWindow = getSinglePageSpreadWindow(step, getSpreadState({
        displayWindow: getCurrentDisplayWindow(),
    }));
    goToPage(requestedDisplayWindow.start, { feedbackKind: "slide", feedbackDirection: Math.sign(step) });
    return true;
}

function shiftRequestedSpreadByPageCount(step) {
    const numericStep = Number(step);
    if (!Number.isFinite(numericStep) || Math.abs(numericStep) !== 1) {
        return false;
    }

    if (!doublePageMode || infiniteScroll || !activeDisplayWindowWasRequested || !activeDisplayWindow
        || activeDisplayWindow.end <= activeDisplayWindow.start) {
        return false;
    }

    const stride = activeDisplayWindowStride || 2;
    requestedDisplayWindow = getSpreadWindowWithPageShift(numericStep > 0 ? stride : -stride, getSpreadState({
        displayWindow: activeDisplayWindow,
    }));
    requestedDisplayWindowStride = stride;
    goToPage(requestedDisplayWindow.start, { feedbackKind: "normal", feedbackDirection: Math.sign(numericStep) });
    return true;
}

function cycleSpreadStart() {
    if (!doublePageMode || infiniteScroll) { return; }
    const modes = ["auto", "pair2"];
    const previous = spreadStart;
    const next = modes[(modes.indexOf(spreadStart) + 1) % modes.length];
    setSpreadStart(next);
    // Persist per-archive (backend: PUT /api/archives/{id}/spreadstart)
    fetch(new LRR.ApiURL(`/api/archives/${id}/spreadstart?value=${next}`), { method: "PUT" })
        .then((response) => {
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
        })
        .catch((error) => {
            setSpreadStart(previous);
            goToPage(currentPage);
            LRR.showErrorToast(I18N.ReaderArchiveError, error);
        });
    goToPage(currentPage);
}

// fork: arm a one-shot capture-phase listener so the first real reading click
// (no overlay open, not already fullscreen) enters fullscreen and is swallowed
// before the bubble-phase page-navigation handler runs.
function armAutoFullscreen() {
    if (!mobileFullscreen || !fscreen.fullscreenEnabled) return;
    const i3 = document.getElementById("i3");
    if (!i3) return;
    function autoFullscreen(e) {
        if (fscreen.inFullscreen() || $("#overlay-shade").is(":visible") || isReaderInteractiveTarget(e.target)) return;
        i3.removeEventListener("click", autoFullscreen, true);
        e.stopPropagation();
        toggleFullScreen();
    }
    i3.addEventListener("click", autoFullscreen, true);
}

function initFullscreen() {
    // Apply full-screen utility
    // F11 Fullscreen is totally another "Fullscreen", so its support is beyond consideration.
    // Small override function, always returns boolean
    fscreen.inFullscreen = () => !!fscreen.fullscreenElement;
    if (!fscreen.fullscreenEnabled) {
        // Fullscreen mode is unsupported; use attribute selector to hide all instances
        $(".toggle-full-screen").hide();
    }

    fscreen.onfullscreenchange = () => handleFullScreen(fscreen.fullscreenElement !== null);
    armAutoFullscreen();
}

function initInfiniteScrollView(initialPageReason = "default-first") {
    $("#Map").remove();
    $("#img_doublepage").remove();
    const firstSource = getReaderImageSource(0);
    $(".reader-image").first()
        .attr("id", "page-0")
        .attr("data-src", firstSource)
        .attr("src", firstSource)
        .attr("loading", "eager");

    // Disable other options that don't work with infinite scroll
    mangaMode = false;
    doublePageMode = false;

    // Create an observer to update progress when a new page is scrolled in
    let allImagesLoaded;
    const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (!entry.isIntersecting) return;
            materializeInfiniteScrollImage(entry.target);

            // Find the entry in the list of images
            const index = entry.target.id.replace("page-", "");
            // Convert to int
            const page = parseInt(index, 10);
            materializeInfiniteScrollWindow(page);
            // Avoid double progress updates
            if (currentPage !== page) {
                currentPage = page;
                updateProgress();
            }
        });
    // A narrow viewport-center band works for both short and very tall pages;
    // threshold: 0.5 never fires when an image is taller than twice the viewport.
    }, { threshold: 0, rootMargin: "-49% 0px -49% 0px" });
    const preloadObserver = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
            if (entry.isIntersecting) materializeInfiniteScrollImage(entry.target);
        });
    }, { rootMargin: "1200px" });

    observer.observe($(".reader-image").first().get(0));
    pages.slice(1).forEach((_source, offset) => {
        const index = offset + 1;
        const source = getReaderImageSource(index);
        const img = new Image();
        img.id = `page-${index}`;
        img.height = 800;
        img.width = 600;
        img.dataset.src = source;
        img.loading = "lazy";
        $(img).addClass("reader-image");
        $("#display").append(img);
        observer.observe(img);
        preloadObserver.observe(img);
    });

    materializeInfiniteScrollWindow(currentPage);
    $("#i3").removeClass("loading");
    $(document).on("click.infinite-scroll-map", "#display .reader-image", (event) => {
        // is click X position is left on screen or right
        if (event.pageX < $(window).width() / 2) {
            changePage(-1, true);
        } else {
            changePage(1, true);
        }
    });

    applyContainerWidth();
    allImagesLoaded = $("#display .reader-image").toArray().every((img) => img.complete || !img.getAttribute("src"));
    if (shouldApplyInitialPageScroll(initialPageReason) && (window.scrollY === 0 || !allImagesLoaded)) {
        requestAnimationFrame(() => {
            if (shouldApplyInitialPageScroll(initialPageReason)) {
                goToPage(currentPage).finally(finishInitialPageScroll);
            } else {
                finishInitialPageScroll();
            }
        });
    } else {
        finishInitialPageScroll();
    }
}

function materializeInfiniteScrollImage(img) {
    const source = img.dataset.src;
    if (source && !img.getAttribute("src")) {
        img.src = source;
    }
}

function materializeInfiniteScrollWindow(centerPage) {
    const start = Math.max(0, centerPage - INFINITE_SCROLL_WINDOW_RADIUS);
    const end = Math.min(maxPage, centerPage + INFINITE_SCROLL_WINDOW_RADIUS);
    for (let page = start; page <= end; page++) {
        const img = document.getElementById(`page-${page}`);
        if (img) materializeInfiniteScrollImage(img);
    }
}

function isEditableShortcutTarget(target) {
    return target?.matches?.("input, textarea, select, [contenteditable='true'], [contenteditable='']");
}

function closeReaderOverlay() {
    LRR.closeOverlay();
    const returnTarget = overlayReturnFocus;
    overlayReturnFocus = null;
    returnTarget?.focus?.();
}

function trapOverlayFocus(e) {
    if (e.key !== "Tab" || !$(e.currentTarget).is(":visible")) return;
    const focusable = [...e.currentTarget.querySelectorAll(
        "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
    )].filter((element) => element.offsetParent !== null);
    if (focusable.length === 0) {
        e.preventDefault();
        e.currentTarget.focus();
        return;
    }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
    }
}

/** Process inputs
 * @param {JQuery.KeyDownEvent<Document, undefined, Document, Document> | JQuery.KeyUpEvent<Document, undefined, Document, Document>} e
*/
function handleShortcuts(e) {
    if (e.key === "Escape" && $(".base-overlay:visible").length) {
        e.preventDefault();
        closeReaderOverlay();
        return;
    }
    if (isEditableShortcutTarget(e.target)) return;

    switch (e.key) {
        case ",":
            readPreviousArchive();
            return;
        case ".":
            readNextArchive();
            return;
    }
    switch (e.which) {
        case 8: // backspace
            returnToIndex();
            break;
        case 27: // escape
            closeReaderOverlay();
            break;
        case 46: // delete
            confirmDeleteArchive();
            break;
        case 32: // spacebar
            spaceScrollProcessInput(e);
            break;
        case 33: // page up
            hideReaderCursorForNavigationInput();
            e.preventDefault();
            if (e.type === "keydown") { break; }
            changePage(-10, true, { respectReadingDirection: false });
            break;
        case 34: // page down
            hideReaderCursorForNavigationInput();
            e.preventDefault();
            if (e.type === "keydown") { break; }
            changePage(10, true, { respectReadingDirection: false });
            break;
        case 35: // end
            hideReaderCursorForNavigationInput();
            e.preventDefault();
            if (e.type === "keydown") { break; }
            changePage("last", true, { respectReadingDirection: false });
            break;
        case 36: // home
            hideReaderCursorForNavigationInput();
            e.preventDefault();
            if (e.type === "keydown") { break; }
            changePage("first", true, { respectReadingDirection: false });
            break;
        case 38: // up arrow
        case 87: // w
            hideReaderCursorForNavigationInput();
            if (shouldSlideSpreadWithVerticalKeys()) { e.preventDefault(); }
            if (e.type !== "keydown" && slideSpreadBySinglePage(-1)) { e.preventDefault(); }
            break;
        case 40: // down arrow
        case 83: // s
            hideReaderCursorForNavigationInput();
            if (shouldSlideSpreadWithVerticalKeys()) { e.preventDefault(); }
            if (e.type !== "keydown" && slideSpreadBySinglePage(1)) { e.preventDefault(); }
            break;
        case 37: // left arrow
            hideReaderCursorForNavigationInput();
            if (e.shiftKey) {
                changePage("first", true);
            } else {
                changePage(-1, true);
            }
            break;
        case 39: // right arrow
            hideReaderCursorForNavigationInput();
            if (e.shiftKey) {
                changePage("last", true);
            } else {
                changePage(1, true);
            }
            break;
        case 65: // a
            hideReaderCursorForNavigationInput();
            if (e.shiftKey) {
                changePage("first", true);
            } else {
                changePage(-1, true);
            }
            break;
        case 66: // b
            toggleBookmark(e);
            break;
        case 68: // d
            hideReaderCursorForNavigationInput();
            if (e.shiftKey) {
                changePage("last", true);
            } else {
                changePage(1, true);
            }
            break;
        case 70: // f
            toggleFullScreen();
            break;

        case 71: // g
            {
                let page = parseInt(prompt(I18N.GoToPage), 10);
                // parseInt returns NaN for non-numbers; normal equality checks don't work to detect NaN
                if (!Number.isNaN(page)) {
                    goToPage(page - 1);
                }
            }
            break;
        case 72: // h
            toggleHelp();
            break;
        case 74: // j - fork: toggle adaptive offset (auto / pair2)
            cycleSpreadStart();
            break;
        case 75: // k
            toggleBorderCrop();
            break;
        case 77: // m
            toggleMangaMode();
            break;
        case 78: // n
            toggleAutoNextPage();
            break;
        case 79: // o
            toggleSettingsOverlay();
            break;
        case 80: // p
            toggleDoublePageMode();
            break;
        case 81: // q
            toggleArchiveOverlay();
            break;
        case 82: // r
            if (e.ctrlKey || e.shiftKey || e.metaKey) { break; }
            sessionStorage.removeItem("navigationState");
            document.location.href = new LRR.ApiURL("/random");
            break;
        default:
            break;
    }
}

/**
 * @param {JQuery.KeyDownEvent | JQuery.KeyUpEvent} e
 */
function spaceScrollProcessInput(e) {
    //Break early and go back to browser default behaviour if overlay is open or gallery has webtoon tag and in infiniteScroll
    if ($(".page-overlay").is(":visible") || e.repeat || (infiniteScroll && content.tags?.includes("webtoon"))) return;

    e.preventDefault();
    // Capture direction now so we dont lose it if shift state changes while held
    let direction = e.shiftKey ? -1 : 1;
    if (mangaMode) direction *= -1;
    const cfg = scrollConfig;

    if (e.type === "keydown") {
        if (!spaceScroll.timeout) {
            spaceScroll.timeout = setTimeout(() => {
                const scrollFn = () => {
                    window.scrollBy({
                        top: direction * (cfg.scrollSpeed / 100 * window.innerHeight)
                    });
                    spaceScroll.animationId = requestAnimationFrame(scrollFn);
                };
                spaceScroll.animationId = requestAnimationFrame(scrollFn);
            }, cfg.holdDelay);
        }
        return;
    }
    else if (e.type === "keyup") {
        clearTimeout(spaceScroll.timeout);
        const wasContinuousScroll = spaceScroll.animationId;
        cancelAnimationFrame(spaceScroll.animationId);
        spaceScroll = { timeout: null, animationId: null };
        const st = window.scrollY;
        const h = window.innerHeight;

        const currentImg = [...document.querySelectorAll(".reader-image")].find(img => {
            const rect = img.getBoundingClientRect();
            return rect.top <= h / 2 && rect.bottom >= h / 2;
        }) || document.querySelector(direction > 0 ? ".reader-image:first-child" : ".reader-image:last-child");

        if (!currentImg) return;

        const imgTop = currentImg.getBoundingClientRect().top + st;
        const imgBottom = currentImg.getBoundingClientRect().bottom + st;
        const directionEdge = direction > 0 ? imgBottom : imgTop;

        // Convert to percentage of pixels compared to window height
        const scrollDistPx = (cfg.scrollDist / 100) * h;
        const overSnapPx = (cfg.overSnap / 100) * h;
        const underSnapPx = (cfg.underSnap / 100) * h;
        // Calculate active thresholds based on direction
        const directionDist = (directionEdge - (direction > 0 ? st + h : st)) * direction;

        // Go to next direction page if already at edge
        if ((direction > 0 ? st + h >= directionEdge - 3 : st <= directionEdge + 3) && !wasContinuousScroll) {
            console.log(`PAGE TURN: ${cfg.scrollDist}% threshold reached`);
            changePage(direction, true);
            return;
        }

        // 2. Continuous scroll overshoot check
        if (wasContinuousScroll) {
            // Calculate actual overshoot distance (positive value)
            const overshootDistance = Math.abs(directionDist) - scrollDistPx;

            if (overshootDistance > overSnapPx) {
                console.log(`CONTINUOUS SNAP: ${overshootDistance.toFixed(1)}px > ${overSnapPx.toFixed(1)}px threshold`);
                const adjImg = direction > 0 ? currentImg.nextElementSibling : currentImg.previousElementSibling;
                if (adjImg) {
                    const adjRect = adjImg.getBoundingClientRect();
                    // Snap to 5px before the edge for better visibility
                    const snapPosition = direction > 0
                        ? adjRect.top + st + 5
                        : adjRect.bottom + st - h - 5;
                    window.scrollTo({ top: snapPosition });
                }
                return;
            }
        }

        // 3. Undershoot prevention
        if (directionDist <= scrollDistPx + underSnapPx) {
            console.log(`UNDERSHOOT SNAP: ${cfg.underSnap}% (${Math.round(directionDist)}px <= ${Math.round(scrollDistPx + underSnapPx)}px)`);
            window.scrollTo({ top: directionEdge - (direction > 0 ? h : 0) });
            return;
        }

        // 4. Default scroll
        console.log(`DEFAULT SCROLL (${Math.abs(directionDist).toFixed(1)}px)`);
        const scrollAmount = direction * scrollDistPx;
        window.scrollBy({ top: scrollAmount });
    }
}

let wheelDebounce = false;

function handleWheel(e) {
    if ($("#settingsOverlay").is(":visible")) return;

    if (shouldWheelNavigatePages({
        infiniteScroll,
        fullscreen: fscreen.inFullscreen(),
        headerHidden: localStorage.hideHeader === "true",
    }) && !wheelDebounce) {
        e.preventDefault();
        const deltaY = e.originalEvent ? e.originalEvent.deltaY : e.deltaY;
        const direction = deltaY > 0 ? -1 : 1;
        wheelDebounce = true;
        hideReaderCursorForNavigationInput();
        changePage(direction, true);
        setTimeout(() => { wheelDebounce = false; }, 100);
    }
}

function checkFiletypeSupport(extension) {
    if ((extension === "rar" || extension === "cbr") && !localStorage.rarWarningShown) {
        localStorage.rarWarningShown = true;
        LRR.toast({
            heading: I18N.ReaderRarWarning,
            text: I18N.ReaderRarWarningDesc,
            icon: "warning",
            hideAfter: 23000,
        });
    } else if (extension === "epub" && !localStorage.epubWarningShown) {
        localStorage.epubWarningShown = true;
        LRR.toast({
            heading: I18N.ReaderEpubWarning,
            text: I18N.ReaderEpubWarningDesc,
            icon: "warning",
            hideAfter: 20000,
            closeOnClick: false,
            draggable: false,
        });
    }
}

function toggleHelp() {
    LRR.toast({
        toastId: "readerHelp",
        heading: I18N.ReaderNavHelp,
        text: $("#reader-help").children().first().html(),
        icon: "info",
        hideAfter: 60000,
    });

    return false;
    // all toggable panes need to return false to avoid scrolling to top
}

const stampLayer = createReaderStamps({
    getState: () => ({ displayWindow: pages?.length ? getCurrentDisplayWindow() : null, mangaMode,
        visible: markersVisible, infiniteScroll, fullscreen: fscreen.inFullscreen() }),
    getArchiveForPage,
    request: (endpoint, method) => Server.callAPISilent(endpoint, method),
    onError: (error) => LRR.showErrorToast(I18N.StampError, error),
    onChange: checkStampedPages,
    setNavigationEnabled: (enabled) => { pageNaviState = enabled; },
});

function renderMarkers() {
    stampLayer.render();
}

function clearMarkers() {
    stampLayer.hide();
}

function toggleStamps() {
    markersVisible = localStorage.markersVisible = !markersVisible;
    if (markersVisible) {
        loadStamps();
    } else {
        stampLayer.clear();
    }
}

function loadStamps() {
    return stampLayer.refresh();
}

function handleMarkerContextMenu(option, stampId) {
    if (infiniteScroll) return;
    const marker = stampLayer.get(stampId);
    if (!marker) return;
    if (option === "deletemarker") {
        stampLayer.remove(marker);
    } else if (option === "editmarker") {
        LRR.showPopUp({
            title: I18N.StampName,
            input: "text",
            inputPlaceholder: I18N.StampPlaceholder,
            inputAttributes: { autocapitalize: "off" },
            inputValue: marker.name,
            showCancelButton: true,
            reverseButtons: true,
        }).then((result) => {
            if (result.isConfirmed && result.value.trim() !== "") {
                stampLayer.edit(marker, result.value);
            }
        });
    }
}

function toggleBookmark(e) {
    e.preventDefault();
    if (!localStorage.getItem("bookmarkCategoryId")) {
        console.error("No bookmark category ID found!");
        return;
    }

    if (!LRR.isUserLogged()) {
        LRR.toast({
            heading: I18N.LoginRequired(new LRR.ApiURL("/login")),
            icon: "warning",
            hideAfter: 5000,
        });
        return;
    }

    const categoryId = localStorage.getItem("bookmarkCategoryId");
    const wasBookmarked = $(".toggle-bookmark").hasClass("fas fa-bookmark");
    const applyBookmarkState = (bookmarked) => {
        if (bookmarked) {
            addCategoryBadge(categoryId);
            $(".toggle-bookmark").removeClass("far fa-bookmark").addClass("fas fa-bookmark").attr("aria-pressed", "true");
        } else {
            removeCategoryBadge(categoryId);
            $(".toggle-bookmark").removeClass("fas fa-bookmark").addClass("far fa-bookmark").attr("aria-pressed", "false");
        }
    };

    applyBookmarkState(!wasBookmarked);
    const request = wasBookmarked
        ? Server.callAPISilent(`/api/categories/${categoryId}/${id}`, "DELETE")
        : Server.callAPISilent(`/api/categories/${categoryId}/${id}`, "PUT");
    request.catch((error) => {
        applyBookmarkState(wasBookmarked);
        LRR.showErrorToast(I18N.CategoryEditError, error);
    });

}

// dynamically add bookmark icon if bookmark link is configured.
function loadBookmarkStatus() {
    Server.loadBookmarkCategoryId().then(
        category_id => {
            if (!LRR.bookmarkLinkConfigured()) {
                return;
            }
            fetch(new LRR.ApiURL(`/api/categories/${category_id}`))
                .then(response => response.json()).then(categoryData => {
                    const isBookmarked = categoryData.archives.includes(id);
                    const bookmarkState = isBookmarked ? "fas" : "far";
                    const disabledClass = LRR.isUserLogged() ? "" : " disabled";
                    const leftOptionsList = document.querySelectorAll(".absolute-options.absolute-left");
                    leftOptionsList.forEach(leftOption => {
                        let bookmark = document.createElement("a");
                        bookmark.className = `${bookmarkState} fa-bookmark fa-2x toggle-bookmark${disabledClass}`;
                        bookmark.href = "#";
                        bookmark.title = I18N.ToggleBookmark;
                        bookmark.setAttribute("aria-label", I18N.ToggleBookmark);
                        bookmark.setAttribute("aria-pressed", isBookmarked ? "true" : "false");
                        if (!LRR.isUserLogged()) {
                            bookmark.setAttribute("style", "opacity: 0.5; cursor: not-allowed;");
                        }
                        leftOption.appendChild(bookmark);
                    });
                });
        }
    );
}

function updateMetadata() {
    metadataRenderGeneration += 1;
    const renderGeneration = metadataRenderGeneration;
    const metadataPage = currentPage;
    const metadataSinglePage = showingSinglePage;
    const isCurrentMetadataRender = () => (
        metadataRenderGeneration === renderGeneration
        && currentPage === metadataPage
        && showingSinglePage === metadataSinglePage
    );

    const img = $("#img")[0];
    const { filename } = img.dataset;

    const imgDoublePage = $("#img_doublepage")[0];
    const filenameDoublePage = imgDoublePage.dataset.filename;

    if (!filename && showingSinglePage) {
        $("#i3").removeClass("loading").attr("aria-busy", "false");
        return;
    }

    const width = img.naturalWidth;
    const height = img.naturalHeight;
    const widthDoublePage = imgDoublePage.naturalWidth;
    const heightDoublePage = imgDoublePage.naturalHeight;
    const widthView = width + widthDoublePage;

    // Render with whatever size info we have now ("—" if unknown); refresh via async HEAD
    // on the cold path instead of blocking the UI thread with a synchronous XHR.
    const renderSingle = (s) => {
        const text = `${filename} :: ${width} x ${height} :: ${s === undefined ? "—" : s} KB`;
        $(".file-info").text(text).attr("title", text);
    };
    const renderDouble = (s1, s2) => {
        const sizeView = (s1 === undefined || s2 === undefined) ? "—" : (s1 + s2);
        $(".file-info").text(`${filename} - ${filenameDoublePage} :: ${widthView} x ${height} :: ${sizeView} KB`);
        $(".file-info").attr("title", `${filename} :: ${width} x ${height} :: ${s1 ?? "—"} KB - ${filenameDoublePage} :: ${widthDoublePage} x ${heightDoublePage} :: ${s2 ?? "—"} KB`);
    };
    const fetchAndStore = (idx) => LRR.getImgSizeAsync(pages[idx]).then((s) => {
        preloadedSizes[idx] = s;
        return s;
    });

    if (showingSinglePage) {
        const size = preloadedSizes[currentPage];
        renderSingle(size);
        if (size === undefined) {
            const idx = currentPage;
            fetchAndStore(idx).then((s) => { if (isCurrentMetadataRender()) renderSingle(s); });
        }
    } else {
        const size = preloadedSizes[currentPage];
        const sizePre = preloadedSizes[currentPage + 1];
        renderDouble(size, sizePre);
        if (size === undefined || sizePre === undefined) {
            const idx = currentPage;
            Promise.all([fetchAndStore(idx), fetchAndStore(idx + 1)]).then(([s1, s2]) => {
                if (isCurrentMetadataRender()) renderDouble(s1, s2);
            });
        }
    }

    // Update page numbers in the paginator
    const newVal = showingSinglePage
        ? currentPage + 1
        : `${currentPage + 1} + ${currentPage + 2}`;
    $(".current-page").each((_i, el) => $(el).html(newVal));

    $("#i3").removeClass("loading").attr("aria-busy", "false");
}

function displayDecodedImages(updates) {
    // Retain the actual last displayed spread, including non-adjacent jumps.
    retainedDecodedSources = new Set(["#img", "#img_doublepage"]
        .map(selector => document.querySelector(selector)?.currentSrc).filter(Boolean));
    pageSlide?.before();
    replaceReaderImages(updates, { onImage: (image) => {
        $(image).off("load.reader-metadata").on("load.reader-metadata", updateMetadata);
    } });
}

function displaySingleImage(image, filename) {
    const emptyImage = new Image();
    displayDecodedImages([
        { selector: "#img", image, filename },
        { selector: "#img_doublepage", image: emptyImage },
    ]);
}

export async function goToPage(page, { resetScroll = true, preserveDisplayWindow = false, feedbackKind = "jump", feedbackDirection } = {}) {
    if (feedbackKind === "slide") cancelAdaptiveOffset();
    const confirmFeedback = spreadFeedback.begin({
        archiveId: id, kind: feedbackKind, direction: feedbackDirection,
        source: getCurrentDisplayWindow(), requested: requestedDisplayWindow,
        enabled: spreadStart === "auto" && !id.startsWith("TANK_") && doublePageMode && !infiniteScroll,
    });
    return Perf.measure("reader.goToPage", async () => {
        const navigation = beginReaderNavigation(readerCursor, page, maxPage);
        const navigationId = navigation.token;
        preloadQueue.clear();
        const displayWindowOverride = requestedDisplayWindow || (preserveDisplayWindow && activeDisplayWindowWasRequested ? activeDisplayWindow : null);
        const displayWindowStrideOverride = requestedDisplayWindow
            ? requestedDisplayWindowStride
            : (preserveDisplayWindow && activeDisplayWindowWasRequested ? activeDisplayWindowStride : null);
        requestedDisplayWindow = null;
        requestedDisplayWindowStride = null;
        const slideFrom = currentPage;
        _previousPage = currentPage;
        const targetPage = navigation.page;
        showingSinglePage = false;
        let navigationFailed = false;

        $("#reader-load-error").hide().attr("data-page", "");
        $("#i3").attr("aria-busy", "true");
        const loadingTimer = setTimeout(() => {
            if (isCurrentNavigation(navigationId)) $("#i3").addClass("loading");
        }, 500);

        try {

            if (infiniteScroll) {
                activeDisplayWindow = null;
                activeDisplayWindowWasRequested = false;
                materializeInfiniteScrollWindow(targetPage);
                if (!isCurrentNavigation(navigationId)) { return; }
                if (resetScroll) {
                    $("#display img").get(targetPage).scrollIntoView({ block: "nearest" });
                }
                if (!commitCurrentNavigation(navigationId, targetPage)) { return; }
            } else {
                if (doublePageMode) {
                // The probe pages (target, target-1, target+1) only populate
                // preloadedDimensions for wide-page detection; they don't depend
                // on each other, so load them concurrently instead of serially.
                // Each writes to distinct preloadedDimensions/preloadedPromises
                // keys, so concurrent loadImage calls don't clobber shared state.
                    const probePages = getDoublePageInitialProbePages(targetPage, maxPage);
                    const probeResults = await Promise.all(
                        probePages.map((probePage) => (
                            preloadedDimensions[probePage] ? Promise.resolve() : loadImage(probePage)
                        ))
                    );
                    const probedImages = new Map(probePages.map((probePage, index) => (
                        [probePage, probeResults[index]]
                    )));
                    if (!isCurrentNavigation(navigationId)) { return; }

                    const probedDisplayWindow = getDisplayWindow(targetPage, getSpreadState({
                        currentPage: targetPage,
                    }));
                    const displayWindow = displayWindowOverride && !displayWindowHasWidePage(displayWindowOverride)
                        ? displayWindowOverride
                        : probedDisplayWindow;
                    const displayStart = displayWindow.start;

                    if (displayWindow.end > displayWindow.start) {
                        const [img1, img2] = await Promise.all([
                            probedImages.get(displayStart) || loadImage(displayStart),
                            probedImages.get(displayWindow.end) || loadImage(displayWindow.end),
                        ]);
                        if (!isCurrentNavigation(navigationId)) { return; }
                        const img1Filename = getFilename(displayStart);
                        const img2Filename = getFilename(displayWindow.end);
                        const [decodedImg1, decodedImg2] = await Promise.all([decodeImage(img1), decodeImage(img2)]);
                        if (!isCurrentNavigation(navigationId)) { return; }
                        activeDisplayWindow = displayWindow;
                        activeDisplayWindowWasRequested = Boolean(displayWindowOverride);
                        activeDisplayWindowStride = displayWindowStrideOverride || 2;
                        if (!commitCurrentNavigation(navigationId, displayStart)) { return; }
                        displayDecodedImages([
                            { selector: "#img", image: mangaMode ? decodedImg2 : decodedImg1,
                                filename: mangaMode ? img2Filename : img1Filename },
                            { selector: "#img_doublepage", image: mangaMode ? decodedImg1 : decodedImg2,
                                filename: mangaMode ? img1Filename : img2Filename },
                        ]);
                        $("#display").addClass("double-mode");
                        updateMetadata();
                        void confirmFeedback(displayWindow, getSpreadState());
                    } else {
                        const img = probedImages.get(displayStart) || await loadImage(displayStart);
                        if (!isCurrentNavigation(navigationId)) { return; }
                        const imgFilename = getFilename(displayStart);
                        const decodedImg = await decodeImage(img);
                        if (!isCurrentNavigation(navigationId)) { return; }
                        activeDisplayWindow = displayWindow;
                        activeDisplayWindowWasRequested = Boolean(displayWindowOverride);
                        activeDisplayWindowStride = displayWindowStrideOverride || 2;
                        if (!commitCurrentNavigation(navigationId, displayStart)) { return; }
                        displaySingleImage(decodedImg, imgFilename);
                        $("#display").removeClass("double-mode");
                        showingSinglePage = true;
                        updateMetadata();
                    }
                } else {
                    const img = await loadImage(targetPage);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    const imgFilename = getFilename(targetPage);
                    const decodedImg = await decodeImage(img);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    if (!commitCurrentNavigation(navigationId, targetPage)) { return; }
                    displaySingleImage(decodedImg, imgFilename);
                    $("#display").removeClass("double-mode");
                    showingSinglePage = true;
                    updateMetadata();
                }

                applyContainerWidth();
                if (pageSlide) {
                    pageSlide.after(Math.sign(currentPage - slideFrom) * (mangaMode ? -1 : 1));
                }
                void configurePageSlide();
                prunePreloadedImages();

                // update full image link
                $("#imgLink").attr("href", pages[currentPage]);

                if (!isCurrentNavigation(navigationId)) { return; }
                if (resetScroll) {
                    window.scrollTo(0, 0);
                }
            }

            if (!isCurrentNavigation(navigationId)) { return; }
            if ($("#archivePagesOverlay").attr("loaded") === "true") updateArchiveOverlay();
            updateProgress();
            if (infiniteScroll) {
                $("#i3").removeClass("loading").attr("aria-busy", "false");
            }
            const ranQueuedNavigation = runQueuedReaderNavigation();
            if (!ranQueuedNavigation && !infiniteScroll) {
                preloadImages();
            }
        } catch (error) {
            if (isCurrentNavigation(navigationId)) {
                navigationFailed = true;
                cancelReaderNavigation(readerCursor);
                $("#reader-load-error")
                    .attr("data-page", targetPage)
                    .css("display", "flex");
                $("#reader-load-error-detail").text(error?.message || String(error));
                console.error(`Failed to load reader page ${targetPage + 1}`, error);
            }
        } finally {
            clearTimeout(loadingTimer);
            if (navigationFailed) {
                $("#i3").removeClass("loading").attr("aria-busy", "false");
            }
        }
    });
}

function updateProgress() {
    stampLayer.clear();

    const page = currentPage + 1; // progress is 1-indexed
    const displayWindow = getCurrentDisplayWindow();
    const syncedProgressPage = getSyncedReadingProgressPageForDisplayWindow(displayWindow, pages.length, page);
    commitReaderSessionPage(page);
    updateSyncedReadingProgress(syncedProgressPage);

    // Load stamps
    if (!infiniteScroll && markersVisible) {
        loadStamps();
    }
}

function estimatePredecodePixels(index) {
    const dimensions = preloadedDimensions[index] || preloadedDimensions[currentPage];
    return dimensions ? dimensions.width * dimensions.height : 2048 * 3072;
}

function preloadImages() {
    const generation = imageLoader.generation();
    const navigationId = readerCursor.token;
    const factor = doublePageMode ? 2 : 1;
    const displayWindow = getCurrentDisplayWindow();
    const preloadState = getSpreadState();
    const nextDisplayPage = getPageNavigationDestination(1, preloadState);
    const nextDisplayWindow = nextDisplayPage <= maxPage
        ? getDisplayWindow(nextDisplayPage, { ...preloadState, currentPage: nextDisplayPage }) : null;
    const forwardStart = nextDisplayWindow?.start ?? displayWindow.end + 1;
    const ahead = [];
    const behind = [];
    const primaryCount = preloadCount * factor;
    const reverseCount = preloadCount > 0 ? factor : 0;
    const forwardCount = preloadDirection > 0 ? primaryCount : reverseCount;
    const backwardCount = preloadDirection < 0 ? primaryCount : reverseCount;
    for (let i = 0; i < forwardCount && forwardStart + i <= maxPage; i++) ahead.push(forwardStart + i);
    for (let i = 1; i <= backwardCount && displayWindow.start - i >= 0; i++) behind.push(displayWindow.start - i);
    const indexes = preloadDirection < 0 ? [...behind, ...ahead] : [...ahead, ...behind];
    const primary = preloadDirection < 0 ? behind : ahead;
    const preloadStrategy = getReaderPreloadStrategy();
    const configured = localStorage.getItem("readerPredecodeCount");
    const requested = configured === null ? MAX_PREDECODED_IMAGES : Number(configured);
    const limit = Number.isInteger(requested) ? Math.max(0, Math.min(MAX_PREDECODED_IMAGES, requested)) : MAX_PREDECODED_IMAGES;
    const predecodeIndexes = new Set();
    let plannedBytes = 0;
    for (const index of primary) {
        const bytes = estimatePredecodePixels(index) * 4;
        if (predecodeIndexes.size >= limit || plannedBytes + bytes > MAX_PREDECODED_BYTES) break;
        predecodeIndexes.add(index);
        plannedBytes += bytes;
    }
    const windowSources = new Set(indexes.map(getReaderImageSource));
    for (let index = displayWindow.start; index <= displayWindow.end; index++) windowSources.add(getReaderImageSource(index));
    predecodeSources = windowSources;
    const isCurrentPreload = () => generation === imageLoader.generation()
        && predecodeSources === windowSources && isCurrentNavigation(navigationId);
    let admittedBytes = 0;

    // Nearest decoded pages have queue priority. Distant byte-only work uses
    // remaining slots, rather than flooding connections needed by navigation.
    for (const index of predecodeIndexes) {
        preloadQueue.schedule(async () => {
            const loaded = await loadImage(index, "low");
            if (!isCurrentPreload()) return;
            const pixels = estimatePredecodePixels(index);
            if (admittedBytes + pixels * 4 > MAX_PREDECODED_BYTES) return;
            admittedBytes += pixels * 4;
            return decodeImage(loaded);
        }, { pixels: estimatePredecodePixels(index), isCurrent: isCurrentPreload })
            .catch(() => {}).finally(prunePreloadedImages);
    }
    for (const index of indexes.filter(index => !predecodeIndexes.has(index))) {
        preloadQueue.schedule(() => preloadStrategy === "blob"
            ? preloadBlobBytesWithFallback(index) : loadImage(index, "low"), {
            pixels: preloadStrategy === "blob" ? 0 : estimatePredecodePixels(index),
            isCurrent: isCurrentPreload,
        }).catch(() => {});
    }
}

function prunePreloadedImages() {
    imageLoader.prune();
}

function revokePreloadedImages() {
    preloadQueue.clear();
    retainedDecodedSources = new Set();
    preloadDirection = 1;
    resetPageSlide();
    imageLoader.invalidate();
    predecodeSources = new Set();
}

window.addEventListener("pagehide", () => {
    flushProgressPersistence({ keepalive: true });
    cancelAdaptiveOffset();
    resetPageSlide();
    preloadQueue.clear();
    retainedDecodedSources = new Set();
    imageLoader.dispose();
    stampLayer.dispose();
});

function decodeImage(loadedImage) {
    // A live effect/neighbor is already decoded even if the bounded decode LRU moved on.
    const retained = pageSlide?.decoded(typeof loadedImage === "string" ? loadedImage : loadedImage?.src);
    if (retained) return Promise.resolve(retained);
    return imageLoader.decode(loadedImage);
}

function getReaderPreloadStrategy() {
    return localStorage.readerPreloadStrategy === "browser" ? "browser" : "blob";
}

async function loadImage(index, priority = "high") {
    const rawSrc = pages[index];
    if (!rawSrc) { return rawSrc; }
    const src = getReaderImageSource(index);

    const displayedImage = index === currentPage ? $("#img").get(0) : null;
    if (!imageLoader.has(src) && displayedImage?.getAttribute("src") === src
        && displayedImage.complete && displayedImage.naturalWidth > 0) {
        preloadedDimensions[index] = {
            width: displayedImage.naturalWidth,
            height: displayedImage.naturalHeight,
        };
        return { src, image: displayedImage };
    }

    try {
        if (getReaderPreloadStrategy() === "browser") {
            return await preloadImageWithBrowserCache(index, src, priority);
        }
        return await preloadImageWithBlobUrl(index, src, priority);
    } catch (e) {
        if (e.name === "AbortError") throw e;
        if (src !== rawSrc) {
            const fallback = await preloadImageWithBlobUrl(index, rawSrc, priority);
            return imageLoader.alias(src, fallback);
        }
        throw e;
    }
}

async function preloadBlobBytesWithFallback(index, requestedSrc = getReaderImageSource(index)) {
    const rawSrc = pages[index];
    const src = requestedSrc;
    try {
        return await imageLoader.bytes(index, src);
    } catch (error) {
        if (error.name === "AbortError") throw error;
        if (src !== rawSrc) {
            const fallback = await imageLoader.bytes(index, rawSrc);
            return imageLoader.alias(src, fallback);
        }
        throw error;
    }
}

function preloadImageWithBlobUrl(index, src, priority) {
    return imageLoader.load(index, src, "blob", priority);
}

function preloadImageWithBrowserCache(index, src, priority) {
    return imageLoader.load(index, src, "browser", priority);
}

function toggleFitMode(e) {
    // possible options: fit-container, fit-width, fit-height
    fitMode = localStorage.fitMode = e.target.id;
    $("#fit-mode input").removeClass("toggled");
    $(e.target).addClass("toggled");

    if (fitMode === "fit-container") {
        $("#container-width").show();
    } else {
        $("#container-width").hide();
    }
    applyContainerWidth();
}

function registerContainerWidth(e) {
    e?.preventDefault();
    // Examples of allowed values: 1200, 1200px, 90%
    // Default value: 1200px
    const input = document.getElementById("container-width-input");
    const raw = input.value.trim();
    if (!raw) { // fall back to default
        input.setCustomValidity("");
        delete state.containerWidth;
        localStorage.removeItem("containerWidth");
    } else {
        const match = /^(\d+)(px|%)?$/.exec(raw);
        if (!match) {
            input.setCustomValidity("Use pixels such as 1200px or a percentage such as 90%.");
            input.reportValidity();
            return false;
        }
        let [, value, type] = match;
        value = Number(value);
        type = type || "px";
        const valid = type === "%" ? value >= 25 && value <= 100 : value >= 320 && value <= 4000;
        if (!valid) {
            input.setCustomValidity(type === "%" ? "Use a value from 25% to 100%." : "Use a value from 320px to 4000px.");
            input.reportValidity();
            return false;
        }
        input.setCustomValidity("");

        state.containerWidth = localStorage.containerWidth = `${value}${type}`;
    }
    applyContainerWidth();
    return false;
}

function getContainerLayoutSignature(fullscreen) {
    return [
        fitMode,
        fullscreen,
        infiniteScroll,
        localStorage.hideHeader === "true",
        state.containerWidth || "",
        showingSinglePage ? "single" : "double",
    ].join("|");
}

function applyContainerWidth() {
    const fullscreen = fscreen.inFullscreen();
    const nextLayoutSignature = getContainerLayoutSignature(fullscreen);
    if (appliedContainerLayoutSignature === nextLayoutSignature) {
        return;
    }
    appliedContainerLayoutSignature = nextLayoutSignature;

    $(".reader-image, .sni").attr("style", "");

    if (fitMode === "fit-height") {
        // Fit to height forces the image to 90% of visible screen height.
        // Hidden-header paginated mode uses the full viewport because bottom chrome is hidden.
        const height = fullscreen ? 100 : getFitHeightViewportPercent(infiniteScroll, localStorage.hideHeader === "true");
        $(".reader-image").attr("style", `height: ${height}vh; max-height: ${height}vh; width: auto; object-fit: contain;`);
        $(".sni").attr("style", "width: fit-content; width: -moz-fit-content; max-width: 100%; margin-left: auto; margin-right: auto");
    } else if (fitMode === "fit-width") {
        $(".reader-image").attr("style", "width: 100%;");
        $(".sni").attr("style", "max-width: 98%");
    } else if (fullscreen) {
        $(".reader-image").attr("style", "width: 100%");
    } else if (state.containerWidth) {
        // If the user defined a custom width, then we can fall back to that one
        $(".sni").attr("style", `width: ${state.containerWidth}; max-width: 100%`);
        $(".reader-image").attr("style", "width: 100%");
    } else if (!showingSinglePage) {
        // Otherwise, if we are showing two pages we can override the default width
        $(".sni").attr("style", "width: 90%; max-width: 90%");
        $(".reader-image").attr("style", "width: 100%");
    } else {
        // Finally, fall back to 1200px width if none of the above matches
        $(".sni").attr("style", "width: 1200px; max-width: 100%");
        $(".reader-image").attr("style", "width: 100%");
    }

    renderMarkers();
    if (infiniteScroll && currentPage >= 0) {
        document.getElementById(`page-${currentPage}`)?.scrollIntoView({ block: "nearest", behavior: "instant" });
    }
    void configurePageSlide();
}

function registerPreload() {
    const rawInputVal = $("#preload-input").val();
    const inputVal = rawInputVal === "" ? null : rawInputVal;
    const storageVal = (localStorage.preloadCount === "" ? null : localStorage.preloadCount);

    const requested = Number(inputVal ?? storageVal ?? 2);
    preloadCount = Number.isFinite(requested) ? Math.max(0, Math.min(MAX_PRELOAD_COUNT, Math.trunc(requested))) : 2;
    $("#preload-input").val(preloadCount);
    localStorage.preloadCount = preloadCount;
}

function toggleDoublePageMode() {
    if (infiniteScroll) { return; }
    doublePageMode = localStorage.doublePageMode = !doublePageMode;
    requestSharedAdaptiveOffset();
    $("#toggle-double-mode input").toggleClass("toggled");
    goToPage(currentPage);
}

function toggleMangaMode() {
    if (infiniteScroll) { return false; }
    resetPageSlide();
    mangaMode = localStorage.mangaMode = !mangaMode;
    $("#toggle-manga-mode input").toggleClass("toggled");
    $(".reading-direction").toggleClass("fa-arrow-left fa-arrow-right");
    if (!showingSinglePage) { goToPage(currentPage); }
    else void configurePageSlide();

    return false;
}

function toggleHeader() {
    if (infiniteScroll) { return false; }
    localStorage.hideHeader = localStorage.hideHeader !== "true";
    $("#toggle-header input").removeClass("toggled");
    $(localStorage.hideHeader === "true" ? "#hide-header" : "#show-header").addClass("toggled");
    applyReaderChromeLayout();
    applyContainerWidth();
    return false;
}

function toggleProgressTracking() {
    ignoreProgress = localStorage.ignoreProgress = !ignoreProgress;
    if (ignoreProgress) { clearPendingProgressPersistence(); }
    $("#toggle-progress input").toggleClass("toggled");
}

function toggleInfiniteScroll() {
    clearMarkers();
    infiniteScroll = localStorage.infiniteScroll = !infiniteScroll;
    $("#toggle-infinite-scroll input").toggleClass("toggled");
    window.location.reload();
}

function registerAutoNextPage() {
    AutoNextPageInterval = +$("#auto-next-page-input").val().trim() || +localStorage.AutoNextPageInterval || 10;
    $("#auto-next-page-input").val(AutoNextPageInterval);
    localStorage.AutoNextPageInterval = AutoNextPageInterval;

    stopAutoNextPage();
}

function startAutoNextPage() {
    autoNextPageCountdown = Math.trunc(AutoNextPageInterval);
    if (autoNextPageCountdown <= 0) {
        LRR.toast({
            heading: I18N.AutoNextPageFailHeader,
            text: I18N.AutoNextPageFailBody,
            icon: "error",
            hideAfter: 5000,
        });
        return;
    }

    autoNextPage = true;

    const aEls = $(".toggle-auto-next-page");
    aEls.removeClass("fa-stopwatch");
    aEls.text(autoNextPageCountdown);

    autoNextPageCountdownTaskId = setInterval(() => {
        if (autoNextPageCountdown <= 0) {
            clearInterval(autoNextPageCountdownTaskId);

            const atLastPage = mangaMode ? currentPage === 0 : currentPage === maxPage;

            if (atLastPage) {
                // At archive boundary: attempt cross-archive navigation.
                // readNextArchive/readPreviousArchive persists slideshow state
                // to sessionStorage; loadImages on the new page resumes it.
                if (archiveIds.length > 0) {
                    if (mangaMode)
                        readPreviousArchive();
                    else
                        readNextArchive();
                }
                stopAutoNextPage();
            } else {
                if (mangaMode)
                    changePage(-1);
                else
                    changePage(1);
                startAutoNextPage();
            }
            return;
        }
        autoNextPageCountdown -= 1;
        aEls.text(autoNextPageCountdown);
    }, 1000);

    requestWakeLock();
}

export function stopAutoNextPage() {
    autoNextPage = false;
    clearInterval(autoNextPageCountdownTaskId);
    $(".toggle-auto-next-page").addClass("fa-stopwatch");
    $(".toggle-auto-next-page").text("");

    releaseWakeLock();
}

function toggleAutoNextPage() {
    autoNextPage ? stopAutoNextPage() : startAutoNextPage();
    return false; // prevent scrolling to top
}

function toggleOverlayByDefault() {
    showOverlayByDefault = localStorage.showOverlayByDefault = !showOverlayByDefault;
    $("#toggle-overlay input").toggleClass("toggled");
}

function toggleSettingsOverlay() {
    stopAutoNextPage();
    return toggleOverlay("#settingsOverlay");
}

function toggleArchiveOverlay() {
    stopAutoNextPage();
    return toggleOverlay("#archivePagesOverlay");
}

function toggleFullScreen() {
    if (fscreen.inFullscreen()) {
        // if already full screen; exit
        fscreen.exitFullscreen();
    } else {
        // else go fullscreen
        // ensure in every case, the correct fullscreen element is binded.
        fscreen.requestFullscreen($("div#i3").get(0));
    }
}

function handleFullScreen(enableFullscreen = false) {
    if (fscreen.inFullscreen() || enableFullscreen === true) {
        if (markersVisible) {
            clearMarkers();
        }
        if ($("body").hasClass("infinite-scroll")) {
            $("div#i3").addClass("fullscreen-infinite");
        } else {
            $("div#i3").addClass("fullscreen");
        }
    } else {
        renderMarkers();
        if ($("body").hasClass("infinite-scroll")) {
            $("div#i3").removeClass("fullscreen-infinite");
        } else {
            $("div#i3").removeClass("fullscreen");
        }
    }
    applyContainerWidth();
    if (!enableFullscreen && infiniteScroll) {
        requestAnimationFrame(() => {
            syncInfiniteScrollCurrentPageFromViewport();
            replaceReaderSessionPage(currentPage + 1);
        });
    }
}

export function getCurrentChapter() {
    return findChapterForPage(currentPage + 1, content.chapters);
}

// Find the current chapter (or nested sub-chapter) for the given page.
function findChapterForPage(page, chapters) {
    if (!chapters) return null;

    for (const chapter of chapters) {
        if (page >= chapter.startPage && page <= chapter.endPage) {
            // Check if there's a more specific nested chapter
            if (chapter.chapters && chapter.chapters.length > 0) {
                const nested = findChapterForPage(page, chapter.chapters);
                if (nested) return nested;
            }
            return chapter;
        }
    }
    return null;
}

function generateThumbnails() {

    // Function to evaluate Minion job progress and update thumbnails as they are generated
    const thumbProgress = function (notes) {
        if (notes.total_pages === undefined || notes.id === undefined) { return; }

        // Look at all the numbered keys in notes, aka notes.1, notes.2..
        for (let i = 1; i <= notes.total_pages; i++) {
            if (Object.hasOwn(notes, i) && notes[i] === "processed") {

                const startPage = id.startsWith("TANK_") ?
                    content.chapters.find(ch => ch.id === notes.id).startPage :
                    1;

                const index = startPage + i - 2; // 0-based global
                pageThumbnails.add(index);

                // Live-update the page thumbnail in the overlay if it's visible
                if ($(`#${index}_spinner`).attr("loaded") !== "true") {
                    // Set image source to the thumbnail
                    const thumbnailUrl = new LRR.ApiURL(`/api/archives/${notes.id}/thumbnail?page=${i}&cachebust=${Date.now()}`);
                    $(`#${index}_thumb`).attr("src", thumbnailUrl);
                    $(`#${index}_spinner`).attr("loaded", true);
                    $(`#${index}_spinner`).hide();
                }
            }
        }
    };

    const fetchThumbsForArc = function(arc) {
        fetch(new LRR.ApiURL(`/api/archives/${arc.id}/files/thumbnails`), {
            method: "POST",
        })
            .then(response => {
                if (response.status === 200) {
                    // Thumbnails are already generated, there's nothing to do. Very nice!
                    for (let idx = arc.startPage - 1; idx < arc.endPage; idx++) {
                        pageThumbnails.add(idx);
                    }
                    $(".ttspinner").hide();
                    return;
                }
                if (response.status === 202) {
                    // Check status and update progress
                    response.json().then((data) => Server.checkJobStatus(
                        data.job,
                        false,
                        (data) => thumbProgress(data.notes), // call progress callback one last time to ensure all thumbs are loaded
                        () => LRR.showErrorToast(I18N.ThumbJobError),
                        thumbProgress,
                    ));
                }
            });
    };

    if (id.startsWith("TANK_"))
        content.chapters.forEach(arc => fetchThumbsForArc(arc)); // Generate thumbnails per archive
    else
        fetchThumbsForArc({
            id: id,
            startPage: 1,
            endPage: content.pages,
        }); // Queue a single minion job for thumbnails
}

/**
 * Change current page in reader.
 *
 * @param {number|"first"|"last"} targetPage    Page step or one of "first" or "last" page.
 * @param {boolean} resetAuto                   Whether to reset current slideshow counter.
 * @param {object} options                      Navigation behavior options.
 * @param {boolean} options.respectReadingDirection Whether manga mode reverses the command.
 */
function changePage(targetPage, resetAuto = false, { respectReadingDirection = true } = {}) {

    // Reset timer if user manually changes pages during slideshow
    if (resetAuto && autoNextPage) {
        autoNextPageCountdown = Math.trunc(AutoNextPageInterval);
        $(".toggle-auto-next-page").text(autoNextPageCountdown);
    }

    const navigation = resolveReaderNavigationInput(targetPage, maxPage, {
        mangaMode,
        respectReadingDirection,
    });

    if ("step" in navigation && navigation.step !== 0 && isReaderNavigationPending(readerCursor)) {
        queueReaderNavigationStep(readerCursor, navigation.step, { resetAuto });
        return;
    }

    // Sync position if in infinite scroll mode
    if (infiniteScroll) {
        syncInfiniteScrollCurrentPageFromViewport();
    }
    let destination;
    if ("destination" in navigation) {
        const { destination: absoluteDestination } = navigation;
        destination = absoluteDestination;
    } else {
        const { step } = navigation;
        if (shiftRequestedSpreadByPageCount(step)) {
            return;
        }
        destination = getPageNavigationDestination(step, getSpreadState());
    }
    if (destination < 0) {
        // Clamp if we're not at the first page, to avoid doublepage mode accidentally yeeting us to previous archive
        if (currentPage > 0) {
            destination = 0;
        } else {
            return readPreviousArchive();
        }
    } else if (destination > maxPage) {
        // Ditto for last page
        if (currentPage < maxPage) {
            destination = maxPage;
        } else {
            return readNextArchive();
        }
    }
    return goToPage(destination, {
        feedbackKind: Math.abs(navigation.step) === 1 ? "normal" : "jump",
        feedbackDirection: Math.sign(navigation.step),
    });
}

function handlePaginator() {
    switch (this.getAttribute("value")) {
        case "outermost-left":
            readPreviousArchive();
            break;
        case "outer-left":
            changePage("first", true);
            break;
        case "left":
            changePage(-1, true);
            break;
        case "right":
            changePage(1, true);
            break;
        case "outer-right":
            changePage("last", true);
            break;
        case "outermost-right":
            readNextArchive();
            break;
        default:
            break;
    }
}

function getFilename(index) {
    return new URLSearchParams(pages[index].split("?")[1]).get("path");
}

/**
 * Determine if current page qualifies for, and sets up, archive navigation state.
 * While in reader mode, navigation state is only supported if user enters reader from index datatables,
 * or if user is already in reader mode with navigation support and switches to a different archive via
 * readNextArchive() or readPreviousArchive().
 *
 * If users enters from carousel or by pasting URL, navigation is not supported.
 *
 * @returns {Promise<boolean>} - whether archive navigation state was set up
 */
async function setupArchiveNavigation() {
    const navigationState = sessionStorage.getItem("navigationState");
    const currArchiveIdsJson = localStorage.getItem("currArchiveIds");
    const {referrer} = document;
    const isDirectNavigation = !referrer || !referrer.includes(window.location.host);
    if (isDirectNavigation) {
        archiveIds = [];
        sessionStorage.removeItem("navigationState");
        return false;
    } else if (navigationState === "datatables" && currArchiveIdsJson) {
        try {
            const ids = JSON.parse(currArchiveIdsJson);
            archiveIds = ids;
            archiveIndex = ids.indexOf(id);
            if (archiveIndex !== -1) {
                $(".archive-nav-link").show();
                if (archiveIndex === 0) {
                    const previousArchives = await loadPreviousDatatablesArchives();
                    if (previousArchives) {
                        localStorage.setItem("previousArchiveIds", JSON.stringify(previousArchives));
                    }
                }
                if (archiveIndex === ids.length - 1) {
                    const nextArchives = await loadNextDatatablesArchives();
                    if (nextArchives) {
                        localStorage.setItem("nextArchiveIds", JSON.stringify(nextArchives));
                    }
                }
            }
        } catch (error) {
            console.error("Error setting up archive navigation state:", error);
            return false;
        }
    }
    return true;
}

async function loadPreviousDatatablesArchives() {
    if (localStorage.getItem("previousArchiveIds")) {
        return JSON.parse(localStorage.getItem("previousArchiveIds"));
    }
    const currentDTPage = parseInt(localStorage.getItem("currDatatablesPage") || "1", 10);
    if (currentDTPage <= 1) return null;
    return loadDatatablesArchives(currentDTPage - 1);
}

async function loadNextDatatablesArchives() {
    if (localStorage.getItem("nextArchiveIds")) {
        return JSON.parse(localStorage.getItem("nextArchiveIds"));
    }
    const currentDTPage = parseInt(localStorage.getItem("currDatatablesPage") || "1", 10);
    return loadDatatablesArchives(currentDTPage + 1);
}

function readPreviousArchive() {
    spreadFeedback.cancel();
    if (fscreen.inFullscreen()) {
        console.warn("[previous] Archive navigation not supported in fullscreen mode.");
        return;
    }
    if (archiveIds.length > 0) {
        let previousArchiveId;
        if (archiveIndex === 0) {
            const previousArchiveIdsJson = localStorage.getItem("previousArchiveIds");
            const currArchiveIdsJson = localStorage.getItem("currArchiveIds");
            if (previousArchiveIdsJson && currArchiveIdsJson) {
                const previousArchiveIds = JSON.parse(previousArchiveIdsJson);
                localStorage.removeItem("previousArchiveIds");
                localStorage.setItem("currArchiveIds", previousArchiveIdsJson);
                localStorage.setItem("nextArchiveIds", currArchiveIdsJson);
                previousArchiveId = previousArchiveIds[previousArchiveIds.length - 1];
                const currentDTPage = parseInt(localStorage.getItem("currDatatablesPage") || "1", 10);
                localStorage.setItem("currDatatablesPage", currentDTPage - 1);
            } else {
                LRR.toast({ text: I18N.ReaderFirstArchive });
                return;
            }
        } else {
            previousArchiveId = archiveIds[archiveIndex - 1];
        }
        if (autoNextPage) {
            sessionStorage.setItem("autoNextPage", "true");
        }
        const newUrl = new LRR.ApiURL(`/reader?id=${previousArchiveId}`).toString();
        window.location.replace(newUrl);
    } else {
        LRR.toast({ text: I18N.ReaderFirstArchive });
    }
}

function readNextArchive() {
    spreadFeedback.cancel();
    if (fscreen.inFullscreen()) {
        console.warn("[next] Archive navigation not supported in fullscreen mode.");
        return;
    }
    if (archiveIds.length > 0) {
        let nextArchiveId;
        if (archiveIndex === archiveIds.length - 1) {
            const nextArchiveIdsJson = localStorage.getItem("nextArchiveIds");
            const currArchiveIdsJson = localStorage.getItem("currArchiveIds");
            if (nextArchiveIdsJson && currArchiveIdsJson) {
                const nextArchiveIds = JSON.parse(nextArchiveIdsJson);
                localStorage.removeItem("nextArchiveIds");
                localStorage.setItem("currArchiveIds", nextArchiveIdsJson);
                localStorage.setItem("previousArchiveIds", currArchiveIdsJson);
                nextArchiveId = nextArchiveIds[0];
                const currentDTPage = parseInt(localStorage.getItem("currDatatablesPage") || "1", 10);
                localStorage.setItem("currDatatablesPage", currentDTPage + 1);
            } else {
                LRR.toast({ text: I18N.ReaderLastArchive });
                return;
            }
        } else {
            nextArchiveId = archiveIds[archiveIndex + 1];
        }
        if (autoNextPage) {
            sessionStorage.setItem("autoNextPage", "true");
        }
        const newUrl = new LRR.ApiURL(`/reader?id=${nextArchiveId}`).toString();
        window.location.replace(newUrl);
    } else {
        LRR.toast({ text: I18N.ReaderLastArchive });
    }
}

/**
 * Loads the archives for the given datatables page so the Reader can navigate
 * between archives across DT page boundaries without re-rendering the index.
 * TODO: given this can drift from how index builds DT search requests we might
 * want to consolidate.
 *
 * @param {number} datatablesPage - The page number to load.
 * @returns {Promise<Array<string>|null>} - The list of archive IDs, or null on error
 */
async function loadDatatablesArchives(datatablesPage) {
    const searchUrl = new LRR.ApiURL(buildReaderNeighborSearch(datatablesPage, localStorage));

    try {
        const response = await fetch(searchUrl.toString(), {
            method: "GET",
            headers: { Accept: "application/json" },
        });
        if (!response.ok) {
            console.error("Failed to fetch archive list:", response.status, response.statusText);
            return null;
        }
        const data = await response.json();
        if (data && data.data && data.data.length > 0) {
            return data.data;
        }
        return null;
    } catch (error) {
        console.error("Failed to fetch archive list:", error);
        return null;
    }
}

/**
 * Return to the index page with state preservation. Navigates to the DT page,
 * search filter, category, and sort order that were active when the user
 * entered reader mode, updated by any cross-DT archive navigation.
 */
function returnToIndex() {
    const indexSearchQuery = localStorage.getItem("currentSearch") || "";
    const indexSelectedCategory = localStorage.getItem("selectedCategory") || "";
    const indexSort = localStorage.getItem("indexSort") || "title";
    const indexOrder = localStorage.getItem("indexOrder") || "asc";
    const currentDTPage = localStorage.getItem("currDatatablesPage") || "1";
    let returnUrl = "/";
    const params = new URLSearchParams();
    if (indexSearchQuery) params.append("q", indexSearchQuery);
    if (indexSelectedCategory) params.append("c", indexSelectedCategory);
    // indexSort is the column's tag-namespace name (sName); the index reads ?sort= by name,
    // so pass it straight through. Title is the default and is omitted, matching buildURLParameters.
    if (indexSort && indexSort !== "title") {
        params.append("sort", indexSort);
    }
    if (indexOrder !== "asc") params.append("sortdir", indexOrder);
    if (currentDTPage !== "1") params.append("p", currentDTPage);
    const queryString = params.toString();
    if (queryString) {
        returnUrl += "?" + queryString;
    }
    window.location.href = new LRR.ApiURL(returnUrl).toString();
}

/**
 * Toggles the visibility of the base-overlay div that's in the given selector.
 * @param {string} selector
 * @returns {boolean}
 */
export function toggleOverlay(selector) {
    if (selector === "#archivePagesOverlay") updateArchiveOverlay();
    const overlay = $(selector);
    if (overlay.is(":visible")) {
        closeReaderOverlay();
    } else {
        overlayReturnFocus = document.activeElement;
        $("#overlay-shade").fadeTo(150, 0.6, () => {
            overlay.attr("aria-hidden", "false").show().trigger("focus");
        });
    }

    return false; // needs to return false to prevent scrolling to top
}
window.addEventListener("resize", () => {
    // Reload the markers everytime the image size changes
    renderMarkers();
});

jQuery(() => {
    $.contextMenu({
        selector: `.marker-context-menu`,
        build: ($trigger, e) => {
            e.preventDefault();
            e.stopPropagation();
            return {
                callback: function (key, _options) {
                    handleMarkerContextMenu(key, $trigger.attr("data-stamp-id"));
                },
                items: {
                    "editmarker": {"name": "Edit Marker", "icon":"fas fa-pen-to-square"},
                    "deletemarker": {"name": "Delete Marker", "icon":"fas fa-minus"},
                }
            };
        }
    });
});

async function requestWakeLock() {
    if (wakeLock !== null) {
        return;
    }
    if (!("wakeLock" in navigator)) {
        console.warn("Wake Lock API is not available. You're likely running in an outdated browser or without HTTPS.");
        return;
    }

    try {
        wakeLock = await navigator.wakeLock.request();

        wakeLock.addEventListener("release", () => {
            wakeLock = null;
        });
    } catch (err) {
        console.warn("Error acquiring wake lock:", err);
    }
}

function releaseWakeLock() {
    if (wakeLock !== null) {
        wakeLock.release();
    }
}
