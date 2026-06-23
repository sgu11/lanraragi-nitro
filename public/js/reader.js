/**
 * Functions to navigate in reader with the keyboard.
 * Also handles the thumbnail archive explorer.
 */
import * as Server from "lrr-server";
import * as LRR from "lrr-common";
import * as Perf from "lrr-perf";
import I18N from "i18n";
import fscreen from "fscreen";
import {
    getFitHeightViewportPercent,
    isReaderMinimalChrome,
    shouldWheelNavigatePages,
} from "lrr-reader-chrome";
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
    isCurrentReaderNavigation,
    isReaderNavigationPending,
    isWidePage,
    normalizeSpreadStartMode,
    queueReaderNavigationStep,
    selectReaderOpeningPage,
    setReaderDisplayPage,
    spreadStartFlags,
} from "lrr-reader-spread";

let id = "";
let force = false;
let previousPage = -1;
let currentPage = -1;
let readerCursor = createReaderCursor(0);
let currentChapter = null;
let showingSinglePage = true;
let pageThumbnails = [];
const MAX_PRELOADED_IMAGES = 8;
const INFINITE_SCROLL_WINDOW_RADIUS = 4;
const PROGRESS_PERSISTENCE_DELAY_MS = 200;
let preloadedImg = {};
let preloadedPromises = {};
let preloadedOrder = [];
let preloadedSizes = {};
let preloadedDimensions = {};   // fork: page index -> { width, height }, for spread rendering decisions
let spaceScroll = { timeout: null, animationId: null };
let imageQuality = "auto";      // fork: reader image-rendering ("auto"|"high-quality"|"smooth-sharp"|"pixelated")
let cropBorders = false;
let mobileFullscreen = true;    // fork: auto-enter fullscreen on first reading click
let spreadStart = "auto";       // fork: adaptive offset mode ("auto" on, "pair2" off)
let detectedFirstSpreadStart = undefined; // fork: server-detected first interior spread anchor ("2"|"4"|"UNKNOWN"|undefined)
let firstSpreadStart = 2;       // fork: first spread anchor (2 => pages 2-3, 4 => pages 3-4)
let activeDisplayWindow = null; // fork: current rendered spread, including one-page vertical slides
let activeDisplayWindowWasRequested = false;
let activeDisplayWindowStride = 2;
let requestedDisplayWindow = null;
let requestedDisplayWindowStride = null;
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
let state = {
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
let currentPageLoaded;
let progress;
let showOverlayByDefault;
let preloadCount;
let AutoNextPageInterval;
let markerMode = false;
let markersVisible = false;
let markers = [];
let overlayFiltered = false;
let pageNaviState = true;

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

    currentPage = readerCursor.displayPage;
    return true;
}

function runQueuedReaderNavigation() {
    const queued = consumeQueuedReaderNavigationStep(readerCursor);
    if (queued) {
        changePage(queued.step, queued.resetAuto);
        return true;
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
            displayWindowStride: 1,
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
    rememberProgressDisplayWindow();
    if (state.authenticateProgress && LRR.isUserLogged()) {
        Server.updateServerSideProgress(id, page, options);
    } else if (state.trackProgressLocally) {
        localStorage.setItem(`${id}-reader`, page);
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

function returnToLibrary() {
    document.location.href = "./";
}

function deleteCurrentArchive() {
    if (id.startsWith("TANK_")) Server.deleteTankoubon(id, returnToLibrary);
    else Server.deleteArchive(id, returnToLibrary);
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

export function initializeAll(trackProgressLocally, authenticateProgress) {
    state.trackProgressLocally = trackProgressLocally;
    state.authenticateProgress = authenticateProgress;

    Perf.initializeLongTaskObserver();
    initializeSettings();
    initFullscreen();
    applyContainerWidth();
    registerPreload();
    registerAutoNextPage();
    document.documentElement.style.scrollBehavior = "smooth";

    // Bind events to DOM
    $(document).on("keyup", (e) => handleShortcuts(e));
    // Restrict keydown to keys that need browser-default suppression.
    $(document).on("keydown", (e) => { if ([32, 38, 40].includes(e.which)) handleShortcuts(e); });
    $(document).on("wheel", handleWheel);

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

    $(document).on("click.close-overlay", "#overlay-shade", LRR.closeOverlay);
    $(document).on("click.toggle-full-screen", "#toggle-full-screen", () => toggleFullScreen());
    // Fork: middle-click anywhere toggles fullscreen (matches the "F or Middle-click" reader help string).
    $(document).on("auxclick.fullscreen", (e) => { if (e.button === 1) { e.preventDefault(); toggleFullScreen(); } });
    // Fork: image-quality selector + auto-fullscreen toggle + double-page spread-start.
    $("#image-quality input").on("click.image-quality", setImageQuality);
    $(document).on("click.toggle-border-crop", "#toggle-border-crop input", toggleBorderCrop);
    $(document).on("click.toggle-border-crop-button", "#toggle-border-crop-button", toggleBorderCrop);
    $(document).on("click.toggle-mobile-fullscreen", "#toggle-mobile-fullscreen input", toggleMobileFullscreen);
    $(document).on("click.toggle-spread-start", "#toggle-spread-start input", cycleSpreadStart);
    $(document).on("click.toggle-auto-next-page", ".toggle-auto-next-page", toggleAutoNextPage);
    $(document).on("click.toggle-archive-overlay", "#toggle-archive-overlay", toggleArchiveOverlay);
    $(document).on("click.toggle-settings-overlay", "#toggle-settings-overlay", toggleSettingsOverlay);
    $(document).on("click.toggle-help", "#toggle-help", toggleHelp);
    $(document).on("click.toggle-stamps", "#toggle-stamps", toggleStamps);
    $(document).on("click.toggle-bookmark", ".toggle-bookmark", toggleBookmark);
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
    $(document).on("click.edit-toc", ".edit-toc", (e) => addTocSection(currentChapter.startPage, currentChapter.name));
    $(document).on("click.remove-toc", ".remove-toc", removeTocSection);

    $(document).on("click.set-thumbnail", ".set-thumbnail", (e) => {
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

        // Compute marker position
        // This basically estimates the percentage of the width and legth of the image
        // where the user clicked, so later from this percentage can be reversed
        // without being affected by if the image got scaled up or down
        const img = e.currentTarget;

        const rect = img.getBoundingClientRect();

        const clickX = e.clientX - rect.left;
        const clickY = e.clientY - rect.top;

        const xPercent = (clickX / rect.width) * 100;
        const yPercent = (clickY / rect.height) * 100;

        const markerData = {
            x: xPercent,
            y: yPercent,
            name: `Marker`,
            left: true,
        };

        const displayWindow = getCurrentDisplayWindow();
        let page = displayWindow.start + 1;

        if (displayWindow.end > displayWindow.start) {
            if (img.id == "img_doublepage") {
                page = displayWindow.end + 1;
                markerData.left = false;
            }
        }
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
                const { arcId, localPage } = getArchiveForPage(page);
                Server.callAPI(`/api/archives/${arcId}/stamps/${localPage}?position=${markerData.x},${markerData.y}&content=${result.value}`, "PUT", "Stamp added!", I18N.StampError,
                    (data) => {
                        markerData.id = data["stamp_id"];
                        markerData.name = result.value;

                        markers.push(markerData);
                        renderMarkers();
                        checkStampedPages();
                    }
                );
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


    // Apply full-screen utility
    // F11 Fullscreen is totally another "Fullscreen", so its support is beyong consideration.
    // Small override function, always returns boolean
    fscreen.inFullscreen = () => !!fscreen.fullscreenElement;
    if (!fscreen.fullscreenEnabled) {
        // Fullscreen mode is unsupported; use attribute selector to hide all instances
        $("[id='toggle-full-screen']").hide();
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
            const artistSearchUrl = `/?sort=0&q=artist%3A${encodeURIComponent(artistName)}%24&`;
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
                click: function(score, element, evt) {

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
    }

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

            detectedFirstSpreadStart = data.firstspreadstart; // fork: server-side adaptive spread-start signal
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
function getArchiveForPage(globalPage) {
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
        <span class="label">${categoryName}</span>
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
            Server.callAPI(`/api/archives/${arcId}/toc?page=${localPage}&title=${result.value}`, "PUT", "Chapter added!", I18N.ReaderTocError,
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
                if ($("#overlay-shade").is(":visible") || !pageNaviState || $(event.target).closest(".absolute-options").length) return;

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
    // Initialize settings and button toggles
    if (localStorage.hideHeader === "true" || false) {
        $("#hide-header").addClass("toggled");
    } else {
        $("#show-header").addClass("toggled");
    }

    mangaMode = localStorage.mangaMode === "true" || false;
    if (mangaMode) {
        $("#manga-mode").addClass("toggled");
        $(".reading-direction").toggleClass("fa-arrow-left fa-arrow-right");
    } else {
        $("#normal-mode").addClass("toggled");
    }

    doublePageMode = localStorage.doublePageMode === "true" || false;
    doublePageMode ? $("#double-page").addClass("toggled") : $("#single-page").addClass("toggled");

    ignoreProgress = localStorage.ignoreProgress === "true" || false;
    ignoreProgress ? $("#untrack-progress").addClass("toggled") : $("#track-progress").addClass("toggled");

    infiniteScroll = localStorage.infiniteScroll === "true" || false;
    $(infiniteScroll ? "#infinite-scroll-on" : "#infinite-scroll-off").addClass("toggled");
    applyReaderChromeLayout();

    showOverlayByDefault = localStorage.showOverlayByDefault === "true" || false;
    $(showOverlayByDefault ? "#show-overlay" : "#hide-overlay").addClass("toggled");

    if (localStorage.fitMode === "fit-width") {
        fitMode = "fit-width";
        $("#fit-width").addClass("toggled");
        $("#container-width").hide();
    } else if (localStorage.fitMode === "fit-height") {
        fitMode = "fit-height";
        $("#fit-height").addClass("toggled");
        $("#container-width").hide();
    } else {
        fitMode = "fit-container";
        $("#fit-container").addClass("toggled");
    }

    state.containerWidth = localStorage.containerWidth;
    if (state.containerWidth) { $("#container-width-input").val(state.containerWidth); }

    markersVisible = localStorage.markersVisible === "true" || false;
    $("#toggle-stamps").prop("checked", markersVisible);

    // fork: image quality / interpolation
    imageQuality = localStorage.imageQuality || "auto";
    $("#image-quality input").removeClass("toggled");
    const qualityMap = { "auto": "#quality-auto", "high-quality": "#quality-high", "smooth-sharp": "#quality-sharp", "pixelated": "#quality-pixelated" };
    $(qualityMap[imageQuality] || "#quality-auto").addClass("toggled");
    applyImageQuality();

    cropBorders = localStorage.cropBorders === "true";
    updateBorderCropToggle();

    // fork: auto-fullscreen-on-first-click
    mobileFullscreen = localStorage.mobileFullscreen !== "false"; // default true
    $(mobileFullscreen ? "#mobile-fullscreen-on" : "#mobile-fullscreen-off").addClass("toggled");
}

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
}

function updateBorderCropToggle() {
    $("#toggle-border-crop input").removeClass("toggled");
    $(cropBorders ? "#border-crop-on" : "#border-crop-off").addClass("toggled");
    $("#toggle-border-crop-button")
        .removeClass("fa-crop fa-crop-alt")
        .addClass(cropBorders ? "fa-crop" : "fa-crop-alt");
}

function shouldRequestBorderCrop(index) {
    if (!cropBorders) { return false; }
    if (index === 0) { return false; }
    if (isWidePage(preloadedDimensions[index])) { return false; }
    return true;
}

function getReaderImageSource(index) {
    const rawSrc = pages[index];
    if (!shouldRequestBorderCrop(index) || !rawSrc) {
        return rawSrc;
    }

    const url = new URL(rawSrc, window.location.href);
    url.searchParams.set("crop", "border");
    return `${url.pathname}${url.search}${url.hash}`;
}

function toggleBorderCrop() {
    cropBorders = !cropBorders;
    localStorage.cropBorders = cropBorders;
    updateBorderCropToggle();
    revokePreloadedImages();
    preloadedDimensions = {};
    preloadedSizes = {};

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

// fork: adaptive offset control, persisted per-archive.
function setSpreadStart(value) {
    spreadStart = normalizeSpreadStartMode(value);
    ({ firstSpreadStart } = spreadStartFlags(spreadStart, detectedFirstSpreadStart));
    $("#toggle-spread-start input").removeClass("toggled");
    $(`#spread-${spreadStart}`).addClass("toggled");
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
    goToPage(requestedDisplayWindow.start);
    return true;
}

function shiftRequestedSpreadByPageCount(step) {
    if (!doublePageMode || infiniteScroll || !activeDisplayWindowWasRequested || !activeDisplayWindow
        || activeDisplayWindow.end <= activeDisplayWindow.start) {
        return false;
    }

    const stride = activeDisplayWindowStride || 2;
    requestedDisplayWindow = getSpreadWindowWithPageShift(step > 0 ? stride : -stride, getSpreadState({
        displayWindow: activeDisplayWindow,
    }));
    requestedDisplayWindowStride = stride;
    goToPage(requestedDisplayWindow.start);
    return true;
}

function cycleSpreadStart() {
    if (!doublePageMode || infiniteScroll) { return; }
    const modes = ["auto", "pair2"];
    const next = modes[(modes.indexOf(spreadStart) + 1) % modes.length];
    setSpreadStart(next);
    // Persist per-archive (backend: PUT /api/archives/{id}/spreadstart)
    fetch(new LRR.ApiURL(`/api/archives/${id}/spreadstart?value=${next}`), { method: "PUT" });
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
        if (fscreen.inFullscreen() || $("#overlay-shade").is(":visible")) return;
        i3.removeEventListener("click", autoFullscreen, true);
        e.stopPropagation();
        toggleFullScreen();
    }
    i3.addEventListener("click", autoFullscreen, true);
}

function initFullscreen() {
    // Apply full-screen utility
    // F11 Fullscreen is totally another "Fullscreen", so its support is beyong consideration.
    // Small override function, always returns boolean
    fscreen.inFullscreen = () => !!fscreen.fullscreenElement;
    if (!fscreen.fullscreenEnabled) {
        // Fullscreen mode is unsupported; use attribute selector to hide all instances
        $("[id='toggle-full-screen']").hide();
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
    }, { threshold: 0.5 });
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

/** Process inputs
 * @param {JQuery.KeyDownEvent<Document, undefined, Document, Document> | JQuery.KeyUpEvent<Document, undefined, Document, Document>} e
*/
function handleShortcuts(e) {
    if (e.target.tagName === "INPUT") {
        return;
    }
    switch (e.which) {
        case 8: // backspace
            document.location.href = $("#return-to-index").attr("href");
            break;
        case 27: // escape
            LRR.closeOverlay();
            break;
        case 46: // delete
            confirmDeleteArchive();
            break;
        case 32: // spacebar
            spaceScrollProcessInput(e);
            break;
        case 38: // up arrow
            if (shouldSlideSpreadWithVerticalKeys()) { e.preventDefault(); }
            if (e.type !== "keydown" && slideSpreadBySinglePage(-1)) { e.preventDefault(); }
            break;
        case 40: // down arrow
            if (shouldSlideSpreadWithVerticalKeys()) { e.preventDefault(); }
            if (e.type !== "keydown" && slideSpreadBySinglePage(1)) { e.preventDefault(); }
            break;
        case 37: // left arrow
            changePage(-1, true);
            break;
        case 39: // right arrow
            changePage(1, true);
            break;
        case 65: // a
            changePage(-1, true);
            break;
        case 66: // b
            toggleBookmark(e);
            break;
        case 68: // d
            changePage(1, true);
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
            document.location.href = new LRR.ApiURL("/random");
            break;
        case 83: // s
            if (!infiniteScroll) {
                addStamp();
            }
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

function addStamp() {
    if (infiniteScroll) return;
    markerMode = true;
    clearMarkers();
    $(".reader-image").css("cursor", "cell");
    $(".reader-image").css("z-index", 22);
    $("#overlay-page").show();
}

function createMarkerElement(markerData, index) {
    if (infiniteScroll) return;
    const img = markerData.left
        ? document.getElementById("img")
        : document.getElementById("img_doublepage");


    const display = document.getElementById("display");
    const container = document.getElementById("i1");

    const marker = document.createElement("div");
    marker.className = "marker marker-context-menu";

    // Compute the px coordinates from the percentage based coordinates
    const rect = img.getBoundingClientRect();
    const xPx = (markerData.x / 100) * rect.width;
    const yPx = (markerData.y / 100) * rect.height;

    const displayRect = display.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();

    let leftFix = rect.left - containerRect.left;
    let topFix = rect.top - containerRect.top;

    if (!markerData.left) {
        // Add the width of the left page plus the left and right margin
        const img = document.getElementById("img");
        leftFix += img.width+2;
    }

    marker.style.left = `${rect.left + xPx - displayRect.left + leftFix}px`;
    marker.style.top = `${rect.top + yPx - displayRect.top + topFix}px`;

    marker.title = markerData.name;
    marker.dataset.index = index;

    // Edit
    let isDragging = false;

    marker.addEventListener("mousedown", (e) => {
        if (e.button !== 0) return;
        e.stopPropagation();
        isDragging = true;

        // So no text gets selected during the D&D
        document.body.style.userSelect = "none";
        pageNaviState = false;
    });

    document.addEventListener("mousemove", (e) => {
        if (!isDragging) return;

        const imgRect = img.getBoundingClientRect();
        const dispRect = display.getBoundingClientRect();

        // Ensure that the stamp remains inside the image
        let x = e.clientX - imgRect.left + leftFix;
        let y = e.clientY - imgRect.top + topFix;

        x = Math.max(leftFix, Math.min(x, imgRect.width + leftFix));
        y = Math.max(topFix, Math.min(y, imgRect.height + topFix));

        marker.style.left = `${imgRect.left + x - dispRect.left}px`;
        marker.style.top = `${imgRect.top + y - dispRect.top}px`;
    });

    document.addEventListener("mouseup", (e) => {
        e.stopPropagation();
        // Each marker individually run this event when on mouseup
        // this line ensures that only one of them execute the action
        // also a good improvement would be to change this to an attachable event only for the dragged marker
        if (!isDragging) return;

        isDragging = false;
        document.body.style.userSelect = "auto";

        const imgRect = img.getBoundingClientRect();

        let x = e.clientX - imgRect.left;
        let y = e.clientY - imgRect.top;

        x = Math.max(0, Math.min(x, imgRect.width));
        y = Math.max(0, Math.min(y, imgRect.height));

        const xPercent = (x / imgRect.width) * 100;
        const yPercent = (y / imgRect.height) * 100;

        const i = marker.dataset.index;
        let inputValue = markerData.name;

        Server.callAPI(`/api/stamps/${markerData.id}?position=${xPercent},${yPercent}`, "PUT", "Stamp updated!", I18N.StampError,
            () => {
                markers[i].x = xPercent;
                markers[i].y = yPercent;

                pageNaviState = true;
                renderMarkers();
            }
        );
    });

    display.appendChild(marker);
}

function renderMarkers() {
    if (infiniteScroll) return;
    // Clean markers
    const existing = document.querySelectorAll(".marker");
    existing.forEach(el => el.remove());

    if (!markersVisible) return;

    // Draw markers
    markers.forEach((markerData, index) => {
        createMarkerElement(markerData, index);
    });
}

function clearMarkers() {
    const existing = document.querySelectorAll(".marker");
    existing.forEach(el => el.remove());
}

function toggleStamps() {
    // Show or hide the markers
    markersVisible = localStorage.markersVisible = !markersVisible;
    renderMarkers();
}

function loadStamps(currentPage) {
    if (infiniteScroll) return;
    markers = [];
    const { arcId: id1, localPage: p1 } = getArchiveForPage(currentPage);
    // Call for the first page
    Server.callAPI(`/api/archives/${id1}/stamps/${p1}`, "GET", null, I18N.ServerInfoError,
        (data) => {
            for (var i = data.result.length - 1; i >= 0; i--) {
                let markerData = {};
                let x = data.result[i].position.split(",")[0];
                let y = data.result[i].position.split(",")[1];
                markerData.x = x;
                markerData.y = y;
                markerData.name = data.result[i].content
                markerData.id = data.result[i].id
                markerData.left = true;
                markers.push(markerData);
            }

            const displayWindow = getCurrentDisplayWindow();
            if (displayWindow.end > displayWindow.start) {

                const { arcId: id2, localPage: p2 } = getArchiveForPage(displayWindow.end + 1);
                // Call for the second page (may be in a different archive for tanks)
                Server.callAPI(`/api/archives/${id2}/stamps/${p2}`, "GET", null, I18N.ServerInfoError,
                    (data) => {
                        for (var i = data.result.length - 1; i >= 0; i--) {
                            let markerData = {};
                            let x = data.result[i].position.split(",")[0];
                            let y = data.result[i].position.split(",")[1];
                            markerData.x = x;
                            markerData.y = y;
                            markerData.name = data.result[i].content
                            markerData.id = data.result[i].id
                            markerData.left = false;
                            markers.push(markerData);
                        }

                        // Render markers
                        renderMarkers();
                    }
                );
            } else {
                // Render markers
                renderMarkers();
            }
        }
    );
}

function handleMarkerContextMenu(option, index) {
    if (infiniteScroll) return;
    let i = parseInt(index);

    switch (option) {
        case "editmarker": {
            let emarker = markers[i];
            let inputValue = emarker.name;

            LRR.showPopUp({
                title: I18N.StampName,
                input: "text",
                inputPlaceholder: I18N.StampPlaceholder,
                inputAttributes: {
                    autocapitalize: "off",
                },
                inputValue,
                showCancelButton: true,
                reverseButtons: true,
            }).then((result) => {
                if (result.isConfirmed && result.value.trim() !== "") {
                    Server.callAPI(`/api/stamps/${emarker.id}?content=${result.value}`, "PUT", "Stamp updated!", I18N.StampError,
                        () => {
                            markers[i].name = result.value;

                            pageNaviState = true;
                            renderMarkers();
                        }
                    );
                } else {
                    pageNaviState = true;
                }
            });
            break;
        }
        case "deletemarker": {
            let dmarker = markers[i];
            Server.callAPI(`/api/stamps/${dmarker.id}`, "DELETE", "Stamp deleted!", I18N.StampError,
                () => {
                    markers.splice(i, 1);
                    renderMarkers();
                    if (markers.length == 0) {
                        checkStampedPages();
                    }
                }
            );
            break;
        }
        default:
            break;
    }
};

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

    if ($(".toggle-bookmark").hasClass("fas fa-bookmark")) {
        // Remove from category
        Server.removeArchiveFromCategory(id, localStorage.getItem("bookmarkCategoryId"));
        removeCategoryBadge(localStorage.getItem("bookmarkCategoryId"));
        $(".toggle-bookmark")
            .removeClass("fas fa-bookmark")
            .addClass("far fa-bookmark");
    } else {
        // Add to category
        Server.addArchiveToCategory(id, localStorage.getItem("bookmarkCategoryId"));
        addCategoryBadge(localStorage.getItem("bookmarkCategoryId"));
        $(".toggle-bookmark")
            .removeClass("far fa-bookmark")
            .addClass("fas fa-bookmark");
    }
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
                        if (!LRR.isUserLogged()) {
                            bookmark.setAttribute("style", "opacity: 0.5; cursor: not-allowed;");
                        }
                        leftOption.appendChild(bookmark);
                    })
                })
        }
    )
}

function updateMetadata() {
    const img = $("#img")[0];
    const { filename } = img.dataset;

    const imgDoublePage = $("#img_doublepage")[0];
    const filenameDoublePage = imgDoublePage.dataset.filename;

    if (!filename && showingSinglePage) {
        currentPageLoaded = true;
        $("#i3").removeClass("loading");
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
            fetchAndStore(idx).then((s) => { if (currentPage === idx) renderSingle(s); });
        }
    } else {
        const size = preloadedSizes[currentPage];
        const sizePre = preloadedSizes[currentPage + 1];
        renderDouble(size, sizePre);
        if (size === undefined || sizePre === undefined) {
            const idx = currentPage;
            Promise.all([fetchAndStore(idx), fetchAndStore(idx + 1)]).then(([s1, s2]) => {
                if (currentPage === idx) renderDouble(s1, s2);
            });
        }
    }

    // Update page numbers in the paginator
    const newVal = showingSinglePage
        ? currentPage + 1
        : `${currentPage + 1} + ${currentPage + 2}`;
    $(".current-page").each((_i, el) => $(el).html(newVal));

    currentPageLoaded = true;
    $("#i3").removeClass("loading");
}

async function goToPage(page, { resetScroll = true, preserveDisplayWindow = false } = {}) {
    return Perf.measure("reader.goToPage", async () => {
        const navigation = beginReaderNavigation(readerCursor, page, maxPage);
        const navigationId = navigation.token;
        const displayWindowOverride = requestedDisplayWindow || (preserveDisplayWindow && activeDisplayWindowWasRequested ? activeDisplayWindow : null);
        const displayWindowStrideOverride = requestedDisplayWindow
            ? requestedDisplayWindowStride
            : (preserveDisplayWindow && activeDisplayWindowWasRequested ? activeDisplayWindowStride : null);
        requestedDisplayWindow = null;
        requestedDisplayWindowStride = null;
        previousPage = currentPage;
        const targetPage = navigation.page;
        showingSinglePage = false;

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
                for (const probePage of getDoublePageInitialProbePages(targetPage, maxPage)) {
                    await loadImage(probePage);
                    if (!isCurrentNavigation(navigationId)) { return; }
                }

                const displayWindow = displayWindowOverride || getDisplayWindow(targetPage, getSpreadState({
                    currentPage: targetPage,
                }));
                const displayStart = displayWindow.start;

                if (displayWindow.end > displayWindow.start) {
                    const img1 = await loadImage(displayStart);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    const img1Filename = getFilename(displayStart);
                    const img2 = await loadImage(displayWindow.end);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    const img2Filename = getFilename(displayWindow.end);
                    await Promise.all([decodeImage(img1), decodeImage(img2)]);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    activeDisplayWindow = displayWindow;
                    activeDisplayWindowWasRequested = Boolean(displayWindowOverride);
                    activeDisplayWindowStride = displayWindowStrideOverride || 2;
                    if (!commitCurrentNavigation(navigationId, displayStart)) { return; }
                    if (mangaMode) {
                        $("#img").attr("src", img2);
                        $("#img").attr("data-filename", img2Filename);
                        $("#img_doublepage").attr("src", img1);
                        $("#img_doublepage").attr("data-filename", img1Filename);
                    } else {
                        $("#img").attr("src", img1);
                        $("#img").attr("data-filename", img1Filename);
                        $("#img_doublepage").attr("src", img2);
                        $("#img_doublepage").attr("data-filename", img2Filename);
                    }
                    $("#display").addClass("double-mode");
                } else {
                    const img = await loadImage(displayStart);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    const imgFilename = getFilename(displayStart);
                    await decodeImage(img);
                    if (!isCurrentNavigation(navigationId)) { return; }
                    activeDisplayWindow = displayWindow;
                    activeDisplayWindowWasRequested = Boolean(displayWindowOverride);
                    activeDisplayWindowStride = displayWindowStrideOverride || 2;
                    if (!commitCurrentNavigation(navigationId, displayStart)) { return; }
                    $("#img").attr("src", img);
                    $("#img").attr("data-filename", imgFilename);
                    $("#img_doublepage").attr("src", "");
                    $("#img_doublepage").attr("data-filename", "");
                    $("#display").removeClass("double-mode");
                    showingSinglePage = true;
                }
            } else {
                const img = await loadImage(targetPage);
                if (!isCurrentNavigation(navigationId)) { return; }
                const imgFilename = getFilename(targetPage);
                await decodeImage(img);
                if (!isCurrentNavigation(navigationId)) { return; }
                if (!commitCurrentNavigation(navigationId, targetPage)) { return; }
                $("#img").attr("src", img);
                $("#img").attr("data-filename", imgFilename);
                $("#img_doublepage").attr("src", "");
                $("#img_doublepage").attr("data-filename", "");
                $("#display").removeClass("double-mode");
                showingSinglePage = true;
            }

            applyContainerWidth();

            currentPageLoaded = false;
            // display overlay if it takes too long to load a page
            setTimeout(() => {
                if (!currentPageLoaded) { $("#i3").addClass("loading"); }
            }, 500);

            // update full image link
            $("#imgLink").attr("href", pages[currentPage]);

            if (!isCurrentNavigation(navigationId)) { return; }
            if (resetScroll) {
                window.scrollTo(0, 0);
            }
        }

        if (!isCurrentNavigation(navigationId)) { return; }
        updateArchiveOverlay();
        updateProgress();
        const ranQueuedNavigation = runQueuedReaderNavigation();
        if (!ranQueuedNavigation && !infiniteScroll) {
            preloadImages();
        }
    });
}

function updateProgress() {
    // Clear markers
    markers = [];
    renderMarkers();

    let page = currentPage + 1; // progress is 1-indexed
    commitReaderSessionPage(page);
    updateSyncedReadingProgress(page);

    // Load stamps
    if (!infiniteScroll) {
        const stamps = loadStamps(page);
    }
}

function preloadImages() {
    let preloadNext = preloadCount;
    let preloadPrev = preloadCount == 0 ? 0 : 1;

    if (doublePageMode) { preloadNext *= 2; preloadPrev *= 2; }

    for (let i = 1; i <= preloadNext; i++) {
        if (currentPage + i > maxPage) { break; }
        loadImage(currentPage + i);
    }
    for (let i = 1; i <= preloadPrev; i++) {
        if (currentPage - i < 0) { break; }
        loadImage(currentPage - i);
    }
}

function touchPreloadedImage(src) {
    preloadedOrder = preloadedOrder.filter((existingSrc) => existingSrc !== src);
    preloadedOrder.push(src);
    prunePreloadedImages();
}

function prunePreloadedImages() {
    while (preloadedOrder.length > MAX_PRELOADED_IMAGES) {
        const src = preloadedOrder.shift();
        const blobUrl = preloadedImg[src];
        if (blobUrl) {
            if (blobUrl.startsWith("blob:")) URL.revokeObjectURL(blobUrl);
            delete preloadedImg[src];
        }
    }
}

function revokePreloadedImages() {
    Object.values(preloadedImg).forEach((blobUrl) => {
        if (blobUrl?.startsWith?.("blob:")) URL.revokeObjectURL(blobUrl);
    });
    preloadedImg = {};
    preloadedPromises = {};
    preloadedOrder = [];
}

window.addEventListener("pagehide", () => {
    flushProgressPersistence({ keepalive: true });
    revokePreloadedImages();
});

async function decodeImage(src) {
    const img = new Image();
    img.src = src;
    return img.decode().catch(() => {});
}

function getReaderPreloadStrategy() {
    return localStorage.readerPreloadStrategy === "browser" ? "browser" : "blob";
}

async function loadImage(index) {
    const rawSrc = pages[index];
    if (!rawSrc) { return rawSrc; }
    const src = getReaderImageSource(index);

    const displayedImage = index === currentPage ? $("#img").get(0) : null;
    if (!preloadedImg[src] && displayedImage?.getAttribute("src") === src && displayedImage.complete) {
        preloadedDimensions[index] = {
            width: displayedImage.naturalWidth,
            height: displayedImage.naturalHeight,
        };
        return src;
    }

    if (getReaderPreloadStrategy() === "browser") {
        return preloadImageWithBrowserCache(index, src);
    }

    return preloadImageWithBlobUrl(index, src);
}

async function preloadImageWithBlobUrl(index, src) {
    if (!preloadedImg[src]) {
        if (!preloadedPromises[src]) {
            preloadedPromises[src] = fetch(src)
                .then(async (res) => {
                    preloadedSizes[index] = parseInt(res.headers.get("Content-Length") / 1024, 10);
                    const blob = await res.blob();
                    return URL.createObjectURL(blob);
                })
                .finally(() => {
                    delete preloadedPromises[src];
                });
        }
        preloadedImg[src] = await preloadedPromises[src];
    }
    touchPreloadedImage(src);

    // Cache natural dimensions for spread/wide-page decisions, separate from
    // the byte sizes in preloadedSizes. Decoded off the already-fetched blob.
    if (!preloadedDimensions[index]) {
        const blobUrl = preloadedImg[src];
        preloadedDimensions[index] = await new Promise((resolve) => {
            const probe = new Image();
            probe.onload = () => resolve({ width: probe.naturalWidth, height: probe.naturalHeight });
            // Don't hang navigation if the blob can't be decoded.
            probe.onerror = () => resolve({ width: 0, height: 0 });
            probe.src = blobUrl;
        });
    }

    return preloadedImg[src];
}

async function preloadImageWithBrowserCache(index, src) {
    if (!preloadedImg[src]) {
        if (!preloadedPromises[src]) {
            preloadedPromises[src] = new Promise((resolve) => {
                const img = new Image();
                img.fetchPriority = index === currentPage ? "high" : "low";
                img.decoding = "async";
                img.onload = () => {
                    preloadedDimensions[index] = {
                        width: img.naturalWidth,
                        height: img.naturalHeight,
                    };
                    resolve(src);
                };
                img.onerror = () => resolve(src);
                img.src = src;
            }).finally(() => {
                delete preloadedPromises[src];
            });
        }
        preloadedImg[src] = await preloadedPromises[src];
    }
    touchPreloadedImage(src);
    return preloadedImg[src];
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

function registerContainerWidth() {
    // Examples of allowed values: 1200, 1200px, 90%
    // Default value: 1200px
    const raw = $("#container-width-input").val().trim();
    if (!raw) { // fall back to default
        delete state.containerWidth;
        localStorage.removeItem("containerWidth");
    } else {
        let value, type;

        [, value, type] = /^(\d+)(px|%)?$/.exec(raw);
        value = value || 1200;
        type = type || "px";

        state.containerWidth = localStorage.containerWidth = `${value}${type}`;
    }
    applyContainerWidth();
}

function applyContainerWidth() {
    $(".reader-image, .sni").attr("style", "");
    const fullscreen = fscreen.inFullscreen();

    if (fitMode === "fit-height") {
        // Fit to height forces the image to 90% of visible screen height.
        // Hidden-header paginated mode uses the full viewport because bottom chrome is hidden.
        const height = fullscreen ? 100 : getFitHeightViewportPercent(infiniteScroll, localStorage.hideHeader === "true");
        $(".reader-image").attr("style", `height: ${height}vh; max-height: ${height}vh; width: auto; object-fit: contain;`);
        $(".sni").attr("style", "width: fit-content; width: -moz-fit-content; max-width: 100%");
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
}

function registerPreload() {
    const rawInputVal = $("#preload-input").val();
    const inputVal = rawInputVal === "" ? null : rawInputVal;
    const storageVal = (localStorage.preloadCount === "" ? null : localStorage.preloadCount);

    preloadCount = inputVal ?? storageVal ?? 2;
    $("#preload-input").val(preloadCount);
    localStorage.preloadCount = preloadCount;
}

function toggleDoublePageMode() {
    if (infiniteScroll) { return; }
    doublePageMode = localStorage.doublePageMode = !doublePageMode;
    $("#toggle-double-mode input").toggleClass("toggled");
    goToPage(currentPage);
}

function toggleMangaMode() {
    if (infiniteScroll) { return false; }
    mangaMode = localStorage.mangaMode = !mangaMode;
    $("#toggle-manga-mode input").toggleClass("toggled");
    $(".reading-direction").toggleClass("fa-arrow-left fa-arrow-right");
    if (!showingSinglePage) { goToPage(currentPage); }

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

            if (mangaMode)
                changePage(-1);
            else
                changePage(1);

            const continueNextPage = mangaMode ? currentPage > 0 : currentPage < maxPage;
            if (continueNextPage) {
                startAutoNextPage();
            } else {
                stopAutoNextPage();
            }
            return;
        }
        autoNextPageCountdown -= 1;
        aEls.text(autoNextPageCountdown);
    }, 1000);
}

function stopAutoNextPage() {
    autoNextPage = false;
    clearInterval(autoNextPageCountdownTaskId);
    $(".toggle-auto-next-page").addClass("fa-stopwatch");
    $(".toggle-auto-next-page").text("");
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

function getCurrentChapter() {
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

function updateArchiveOverlay(forceUpdate = false) {
    $("#extract-spinner").hide();

    // Check if the overlay actually needs to be updated
    // If it's already loaded and we're still in the same chapter (or no chapter), do nothing
    if ($("#archivePagesOverlay").attr("loaded") === "true" && !forceUpdate) {

        if ((currentChapter === null) ||
            (currentPage + 1 >= currentChapter.startPage &&
             currentPage + 1 <= currentChapter.endPage)) {
            return;
        }
    }

    // Reset stamp filter state when the overlay is rebuilt for a new chapter
    if (overlayFiltered) {
        overlayFiltered = false;
        $("#filter-stamped").removeClass("toggled");
    }

    // Otherwise, update chapter and overlay -- If there are no chapters defined, just show all pages
    currentChapter = getCurrentChapter();
    let firstPage = currentChapter ? currentChapter.startPage : 1;
    let lastPage = currentChapter ? currentChapter.endPage : pages.length;

    $("#overlay-section").html(currentChapter ? currentChapter.name : I18N.ReaderPages);

    if (currentChapter !== null) {
        // Create <select> options for jumping to other chapters
        let chapterOptions = `<select class="favtag-btn" id="chapter-select">`;
        if (content.chapters) {
            content.chapters.forEach((chapter) => {
                const selected = (currentChapter && chapter.startPage === currentChapter.startPage) ? "selected" : "";
                chapterOptions += `<option value="${chapter.startPage}" ${selected}>${chapter.name}</option>`;

                if (chapter.chapters && chapter.chapters.length > 0) {
                    chapter.chapters.forEach((subChapter) => {
                        const subSelected = (currentChapter && subChapter.startPage === currentChapter.startPage) ? "selected" : "";
                        chapterOptions += `<option value="${subChapter.startPage}" ${subSelected}>&nbsp;&nbsp;&nbsp;${subChapter.name}</option>`;
                    });
                }
            });
        }
        chapterOptions += `</select>`;

        if (LRR.isUserLogged() && currentChapter.chapters === null ) // Only show edit/delete options for leaf chapters
            chapterOptions += `<a class="fas fa-pencil-alt edit-toc" href="#" style="padding:8px; font-size:14px" title="${I18N.ReaderEditToc}"/>
                            <a class="fas fa-trash-alt remove-toc" href="#" style="padding:8px; font-size:14px" title="${I18N.ReaderDeleteToc}"/>`;

        $(".chapter-selector").html(chapterOptions);

        $("#chapter-select").off("change").on("change", function () {
            goToPage($(this).val() - 1);
        });
    } else {
        $(".chapter-selector").html("");
    }

    // For each link in the pages array, craft a div and jam it in the overlay.
    let htmlBlob = "";
    for (let page = firstPage; page < lastPage + 1; ++page) {
        const index = page - 1;

        const thumbCss = (localStorage.cropthumbs === "true") ? "id3" : "id3 nocrop";
        const { arcId, localPage } = getArchiveForPage(page);
        const thumbnailUrl = new LRR.ApiURL(`/api/archives/${arcId}/thumbnail?page=${localPage}`);
        
        let thumbnail = `
            <div class='${thumbCss} quick-thumbnail' page='${index}' style='display: inline-block; cursor: pointer'>
                <span class='page-number'>${I18N.ReaderPage(page)}</span>
                <img src="${thumbnailUrl}" id="${index}_thumb" loading="lazy" />`;
        
        if (LRR.isUserLogged()) 
            thumbnail += `<a href="#" style="padding:12px; top:2%; left:72%;" 
                             title="${I18N.ReaderSetPageAsThumbnail}" 
                             class="fas fa-file-image page-number set-thumbnail"></a>
                          <a href="#" style="padding:12px; top:80%; left:72%;" 
                             title="${I18N.ReaderAddToc}" 
                             class="fas fa-book-medical page-number add-toc"></a>`;

        if (pageThumbnails.includes(index)) thumbnail +=
            `</div>`;
        else thumbnail += 
                `<i id="${index}_spinner" class="fa fa-4x fa-circle-notch fa-spin ttspinner" style="display:flex;justify-content: center; align-items: center;"></i>
            </div>`;

        htmlBlob += thumbnail;
    }

    // NOTE: This can be slow on huge archives and on slower devices, due to the huge DOM change.
    Perf.measure("reader.overlay", () => {
        $("#pages-section").html(htmlBlob);
    });
    $("#archivePagesOverlay").attr("loaded", "true");
    checkStampedPages();
}

function checkStampedPages() {
    const { arcId, localPage } = getArchiveForPage(currentPage + 1);
    Server.callAPI(`/api/archives/${arcId}/stamps/`, "GET", null, I18N.ServerInfoError,
        (data) => {
            $("#extract-spinner").hide();
            cleanStampedPages();
            let pages = data.result.sort();
            let elements = $("div.id3.quick-thumbnail");

            for (let element of elements) {
                let page = parseInt(element.getAttribute("page"));
                const { _, localPage } = getArchiveForPage(page+1);

                if (pages.includes((localPage).toString())) {
                    element.dataset.stamped = true;
                }
            }
        }
    );
}

function cleanStampedPages() {
    let elements = $("div.id3.quick-thumbnail[data-stamped=true]");

    for (let element of elements) {
        delete element.dataset.stamped;
    }
}

function filterStampedOverlay() {
    let elements = $("div.id3.quick-thumbnail");

    if (overlayFiltered) {
        overlayFiltered = false;
        $("#filter-stamped").removeClass("toggled");
        for (let element of elements) {
            element.style.display = `inline-block`;
        }
    } else {
        overlayFiltered = true;
        $("#filter-stamped").addClass("toggled");
        for (let element of elements) {
            if (!element.dataset.stamped) {
                element.style.display = `none`;
            }
        }
    }
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
                pageThumbnails.push(index);

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
        fetch(new LRR.ApiURL(`/api/archives/${arc.id}/files/thumbnails`), { method: "POST" })
            .then(response => {
                if (response.status === 200) {
                    // Thumbnails are already generated, there's nothing to do. Very nice!
                    for (let idx = arc.startPage - 1; idx < arc.endPage; idx++) {
                        pageThumbnails.push(idx);
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
 * @param {(-1|1|"first"|"last")} targetPage    One of -1 (previous), 1 (next), "first", or "last" page.
 * @param {boolean} resetAuto                   Whether to reset current slideshow counter.
 */
function changePage(targetPage, resetAuto = false) {

    // Reset timer if user manually changes pages during slideshow
    if (resetAuto && autoNextPage) {
        autoNextPageCountdown = Math.trunc(AutoNextPageInterval);
        $(".toggle-auto-next-page").text(autoNextPageCountdown);
    }

    if (Number.isFinite(Number(targetPage)) && isReaderNavigationPending(readerCursor)) {
        queueReaderNavigationStep(readerCursor, targetPage, { resetAuto });
        return;
    }

    // Sync position if in infinite scroll mode
    if (infiniteScroll) {
        syncInfiniteScrollCurrentPageFromViewport();
    }
    let destination;
    if (targetPage === "first") {
        destination = mangaMode ? maxPage : 0;
    } else if (targetPage === "last") {
        destination = mangaMode ? 0 : maxPage;
    } else {
        const step = mangaMode ? -targetPage : targetPage;
        if (shiftRequestedSpreadByPageCount(step)) {
            return;
        }
        destination = getPageNavigationDestination(step, getSpreadState());
    }
    goToPage(destination);
}

function handlePaginator() {
    switch (this.getAttribute("value")) {
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
        default:
            break;
    }
}

function getFilename(index) {
    return new URLSearchParams(pages[index].split("?")[1]).get("path");
}

/**
 * Toggles the visibility of the base-overlay div that's in the given selector.
 * @param {string} selector
 * @returns {boolean}
 */
function toggleOverlay(selector) {
    updateArchiveOverlay();
    const overlay = $(selector);
    overlay.is(":visible")
        ? LRR.closeOverlay()
        : $("#overlay-shade").fadeTo(150, 0.6, () => overlay.show());

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
                callback: function (key, options) {
                    handleMarkerContextMenu(key, $(this).attr("data-index"));
                },
                items: {
                    "editmarker": {"name": "Edit Marker", "icon":"fas fa-pen-to-square"},
                    "deletemarker": {"name": "Delete Marker", "icon":"fas fa-minus"},
                }
            }
        }
    });
});
