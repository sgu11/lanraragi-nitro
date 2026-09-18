/**
 * Pure double-page "spread-start" logic for the reader. No DOM or browser
 * globals, so it can be unit tested directly under `node --test`
 * (see tests/js/reader-spread.test.mjs).
 *
 * Spread-start modes:
 *   "auto"  - use server-detected first interior spread start
 *   "pair2" - cover alone, then pair page 2 with page 3
 */

export function normalizeReaderPage(page, maxPage = Number.MAX_SAFE_INTEGER) {
    const lastPage = Math.max(0, Number(maxPage) || 0);
    const pageNumber = Math.trunc(Number(page));
    if (!Number.isFinite(pageNumber)) {
        return 0;
    }
    return Math.max(0, Math.min(lastPage, pageNumber));
}

/**
 * Convert the visible 1-indexed page into persisted reading progress.
 * Reaching the final page keeps the completed page count persisted so Library
 * read-status and hide-completed filters remain correct. Reader reopening is
 * handled separately by selectReaderOpeningPage(), which does not resume the
 * final page.
 */
export function getSyncedReadingProgressPage(page, pageCount) {
    const currentPage = Math.max(0, Math.trunc(Number(page)) || 0);
    const totalPages = Math.max(0, Math.trunc(Number(pageCount)) || 0);

    if (totalPages > 0 && currentPage >= totalPages) {
        return totalPages;
    }
    return currentPage;
}

/**
 * Convert the visible display window into persisted reading progress.
 * A double-page navigation cursor points at the first page in a spread, so
 * completion must be derived from the window's visible end instead.
 */
export function getSyncedReadingProgressPageForDisplayWindow(displayWindow, pageCount, fallbackPage = 0) {
    const endPage = Number(displayWindow?.end);
    return getSyncedReadingProgressPage(
        Number.isFinite(endPage) ? endPage + 1 : fallbackPage,
        pageCount,
    );
}

/**
 * Resolve a reader navigation command into either an absolute destination or
 * a relative step. Horizontal page turns follow manga reading direction;
 * page-number jumps can opt out so keyboard conventions stay stable.
 */
export function resolveReaderNavigationInput(targetPage, maxPage, {
    mangaMode = false,
    respectReadingDirection = true,
} = {}) {
    const lastPage = Math.max(0, Number(maxPage) || 0);
    const reverse = Boolean(mangaMode && respectReadingDirection);

    if (targetPage === "first") {
        return { destination: reverse ? lastPage : 0 };
    }
    if (targetPage === "last") {
        return { destination: reverse ? 0 : lastPage };
    }

    const numericStep = Number(targetPage);
    const step = Number.isFinite(numericStep) ? numericStep : 0;
    return { step: reverse ? -step : step };
}

export function getDoublePageInitialProbePages(targetPage, maxPage) {
    const lastPage = Math.max(0, Number(maxPage) || 0);
    const page = normalizeReaderPage(targetPage, lastPage);
    const probePages = [page];

    if (page === 0) {
        return probePages;
    }
    if (page > 0) {
        probePages.push(page - 1);
    }
    if (page < lastPage) {
        probePages.push(page + 1);
    }
    return probePages;
}

export function createReaderCursor(initialPage = 0) {
    return {
        displayPage: normalizeReaderPage(initialPage),
        pendingPage: null,
        token: 0,
        queuedRelativeStep: 0,
        queuedResetAuto: false,
    };
}

export function beginReaderNavigation(cursor, targetPage, maxPage) {
    cursor.token += 1;
    cursor.pendingPage = normalizeReaderPage(targetPage, maxPage);
    cursor.queuedRelativeStep = 0;
    cursor.queuedResetAuto = false;
    return {
        token: cursor.token,
        page: cursor.pendingPage,
    };
}

export function isCurrentReaderNavigation(cursor, token) {
    return cursor.token === token;
}

export function isReaderNavigationPending(cursor) {
    return cursor.pendingPage !== null;
}

export function commitReaderNavigation(cursor, token, displayPage, maxPage) {
    if (!isCurrentReaderNavigation(cursor, token)) {
        return false;
    }

    cursor.displayPage = normalizeReaderPage(displayPage, maxPage);
    cursor.pendingPage = null;
    return true;
}

export function cancelReaderNavigation(cursor) {
    cursor.token += 1;
    cursor.pendingPage = null;
    cursor.queuedRelativeStep = 0;
    cursor.queuedResetAuto = false;
}

export function setReaderDisplayPage(cursor, page, maxPage) {
    cursor.displayPage = normalizeReaderPage(page, maxPage);
    return cursor.displayPage;
}

export function queueReaderNavigationStep(cursor, step, { resetAuto = false } = {}) {
    const numericStep = Number(step);
    if (!Number.isFinite(numericStep) || numericStep === 0) {
        return false;
    }

    cursor.queuedRelativeStep = numericStep;
    cursor.queuedResetAuto = Boolean(resetAuto);
    return true;
}

export function consumeQueuedReaderNavigationStep(cursor) {
    if (!cursor.queuedRelativeStep) {
        return null;
    }

    const queued = {
        step: cursor.queuedRelativeStep,
        resetAuto: cursor.queuedResetAuto,
    };
    cursor.queuedRelativeStep = 0;
    cursor.queuedResetAuto = false;
    return queued;
}

export function selectReaderOpeningPage({
    explicitPage = null,
    progressPage = null,
    progressEnabled = false,
    userInteractedBeforeInitialPageScroll = false,
    maxPage = 0,
} = {}) {
    if (Number.isInteger(explicitPage)) {
        return {
            page: normalizeReaderPage(explicitPage, maxPage),
            reason: "explicit-page",
        };
    }

    const syncedProgressPage = Number(progressPage);
    if (progressEnabled && !userInteractedBeforeInitialPageScroll
        && Number.isFinite(syncedProgressPage) && syncedProgressPage > 0 && syncedProgressPage < maxPage) {
        return {
            page: normalizeReaderPage(syncedProgressPage, maxPage),
            reason: "resume-progress",
        };
    }

    return { page: 0, reason: "default-first" };
}

export function normalizeFirstSpreadStart(firstSpreadStart) {
    if (firstSpreadStart === 2 || firstSpreadStart === "2") {
        return 2;
    }
    if (firstSpreadStart === 4 || firstSpreadStart === "4") {
        return 4;
    }
    if (firstSpreadStart === 3 || firstSpreadStart === "3") {
        return 4;
    }
    return undefined;
}

export function normalizeSpreadStartMode(mode) {
    if (mode === "auto" || mode === "pair2") {
        return mode;
    }
    if (mode === "always" || mode === "none") {
        return "pair2";
    }
    return "auto";
}

export function isWidePage(dimensions) {
    return Boolean(dimensions && dimensions.width > dimensions.height);
}

export function resolveFirstSpreadStart(mode, firstSpreadStart) {
    const spreadMode = normalizeSpreadStartMode(mode);
    if (spreadMode === "pair2") {
        return 2;
    }

    return normalizeFirstSpreadStart(firstSpreadStart) || 2;
}

export function shouldPairPageTwoWithThree(mode, firstSpreadStart) {
    return resolveFirstSpreadStart(mode, firstSpreadStart) === 2;
}

/** Derive the reader's spread flags from a spread-start mode and detection. */
export function spreadStartFlags(mode, firstSpreadStart) {
    return {
        firstSpreadStart: resolveFirstSpreadStart(mode, firstSpreadStart),
    };
}

// buildSpreadWindows is O(maxPage) and is called from getDisplayWindow,
// getPageNavigationDestination, and getSpreadState on every double-page turn.
// It is a pure function of (maxPage, doublePageMode, firstSpreadStart,
// widePages), so memoize it on a signature of those inputs and only rebuild
// when one of them changes. widePages is a Set; join its (sorted) members so
// two Sets with the same contents produce the same signature.
let spreadWindowsCache = null;
let spreadWindowsSignature = null;

/** Post-wide anchors belong to one archive/content revision. The stored end is
 * an upper bound: a newly observed wide page always starts a new segment.
 * Human corrections outrank inferred anchors within that same segment.
 */
export function resolveSegmentAnchors(maxPage, state) {
    const anchors = new Map();
    if (typeof state.archiveId !== "string" || !state.archiveId
        || typeof state.contentRevision !== "string" || !/^[a-f0-9]{64}$/.test(state.contentRevision)
        || !Array.isArray(state.segments)) return anchors;

    for (const segment of state.segments) {
        if (!segment || segment.archiveId !== state.archiveId || segment.contentRevision !== state.contentRevision
            || segment.boundary !== "until_next_wide" || !["detector", "user_slide"].includes(segment.provenance)) continue;
        const { segmentStart, segmentEnd, firstPairStart } = segment;
        if (!Number.isInteger(segmentStart) || segmentStart < 2 || !state.widePages?.has(segmentStart - 1)
            || state.widePages.has(segmentStart) || !Number.isInteger(segmentEnd) || segmentEnd <= segmentStart
            || segmentEnd > maxPage + 1 || ![segmentStart, segmentStart + 1].includes(firstPairStart)
            || firstPairStart >= segmentEnd) continue;
        const priority = segment.provenance === "user_slide" ? 1 : 0;
        const previous = anchors.get(segmentStart);
        if (!previous || priority > previous.priority) {
            anchors.set(segmentStart, { segmentStart, segmentEnd, firstPairStart, priority });
        } else if (priority === previous.priority && (previous.firstPairStart !== firstPairStart || previous.segmentEnd !== segmentEnd)) {
            anchors.set(segmentStart, { ...previous, firstPairStart: null });
        }
    }
    return anchors;
}

/** Bounded reader polling. A cancelled request can never deliver late evidence.
 * The caller cancels on archive departure, manual slides and adaptive-off.
 */
export function loadAdaptiveOffset({ archiveId, request, commit, intervalMs = 1500, attempts = 20, timeoutMs = 30000 }) {
    const controller = new AbortController();
    let timer;
    let remaining = attempts;
    const deadline = setTimeout(() => controller.abort(), timeoutMs);
    const cancel = () => { controller.abort(); clearTimeout(timer); clearTimeout(deadline); };
    const poll = async () => {
        if (controller.signal.aborted || remaining <= 0) { cancel(); return; }
        remaining -= 1;
        try {
            const result = await request(controller.signal);
            if (controller.signal.aborted) return;
            if (result.status === "disabled") { cancel(); return; }
            if (result.archiveId === archiveId && /^[a-f0-9]{64}$/.test(result.contentRevision || "")
                && result.status === "ready" && ["2", "4", "UNKNOWN"].includes(String(result.first_spread_start))) {
                commit(result);
                cancel();
                return;
            }
        } catch (error) {
            if (controller.signal.aborted || error?.name === "AbortError") { cancel(); return; }
        }
        if (remaining > 0) timer = setTimeout(poll, intervalMs);
        else cancel();
    };
    poll();
    return cancel;
}

function buildSpreadWindowsMemoized(maxPage, state) {
    const widePages = state.widePages || new Set();
    const wideKey = [...widePages].sort((a, b) => a - b).join(",");
    const anchors = resolveSegmentAnchors(maxPage, state);
    const segmentKey = [...anchors.values()].sort((a, b) => a.segmentStart - b.segmentStart)
        .map(({ segmentStart, segmentEnd, firstPairStart }) => `${segmentStart}:${segmentEnd}:${firstPairStart}`).join(",");
    const signature = `${Number(maxPage) || 0}|${state.doublePageMode ? 1 : 0}|${state.firstSpreadStart}|${wideKey}|${segmentKey}`;

    if (spreadWindowsCache && spreadWindowsSignature === signature) {
        return spreadWindowsCache;
    }

    spreadWindowsSignature = signature;
    spreadWindowsCache = buildSpreadWindowsUncached(maxPage, state, anchors);
    return spreadWindowsCache;
}

function buildSpreadWindowsUncached(maxPage, state, anchors) {
    const windows = [];
    const lastPage = Math.max(0, Number(maxPage) || 0);
    const widePages = state.widePages || new Set();

    if (!state.doublePageMode) {
        for (let page = 0; page <= lastPage; page += 1) {
            windows.push({ start: page, end: page });
        }
        return windows;
    }

    const firstPairPage = (normalizeFirstSpreadStart(state.firstSpreadStart) || 2) === 4 ? 2 : 1;
    let lastWide = 0;

    for (let page = 0; page <= lastPage;) {
        if (widePages.has(page)) lastWide = page;
        const local = anchors.get(lastWide + 1);
        const leadingSingle = local?.firstPairStart === page + 1 && local.segmentStart === page && page < local.segmentEnd;
        if (page === 0 || page < firstPairPage || widePages.has(page) || leadingSingle) {
            windows.push({ start: page, end: page });
            page += 1;
            continue;
        }

        if (page + 1 <= lastPage && !widePages.has(page + 1)) {
            windows.push({ start: page, end: page + 1 });
            page += 2;
            continue;
        }

        windows.push({ start: page, end: page });
        page += 1;
    }

    return windows;
}

// Public, memoized entry point. Existing callers pass (maxPage, state); keep
// the signature stable and memoize internally.
export function buildSpreadWindows(maxPage, state) {
    return buildSpreadWindowsMemoized(maxPage, state);
}

/**
 * Infer a human-selected archive offset from a committed two-page display
 * window. A window is useful feedback only when exactly one of the two
 * supported first-spread anchors would produce it under the reader's current
 * wide-page knowledge.
 */
export function inferFirstSpreadStartFromDisplayWindow(displayWindow, state) {
    const start = Number(displayWindow?.start);
    const end = Number(displayWindow?.end);
    const widePages = state.widePages || new Set();

    if (!state.doublePageMode || !Number.isInteger(start) || !Number.isInteger(end)
        || end !== start + 1 || start <= 0 || end > state.maxPage
        || widePages.has(start) || widePages.has(end)) {
        return undefined;
    }

    const matches = [2, 4].filter((firstSpreadStart) => (
        buildSpreadWindowsMemoized(state.maxPage, {
            ...state,
            firstSpreadStart,
        }).some((window) => window.start === start && window.end === end)
    ));

    return matches.length === 1 ? matches[0] : undefined;
}

export function getDisplayWindow(page, state) {
    const currentPage = Math.max(0, Number(page) || 0);
    const windows = buildSpreadWindows(state.maxPage, state);
    return windows.find((window) => currentPage >= window.start && currentPage <= window.end)
        || windows[windows.length - 1]
        || { start: 0, end: 0 };
}

export function getPageNavigationDestination(targetPage, state) {
    const step = Number(targetPage) || 0;
    const currentPage = Math.max(0, Number(state.currentPage) || 0);

    if (!state.doublePageMode) {
        if (step < 0 && currentPage === 0) return -1;
        if (step > 0 && currentPage === state.maxPage) return state.maxPage + 1;
        return Math.max(0, Math.min(state.maxPage, currentPage + step));
    }

    const windows = buildSpreadWindows(state.maxPage, state);
    const currentIndex = windows.findIndex((window) => currentPage >= window.start && currentPage <= window.end);
    if (currentIndex === -1) {
        return getDisplayWindow(currentPage, state).start;
    }

    if (Math.abs(step) === 1) {
        if (step < 0 && currentIndex === 0) return -1;
        if (step > 0 && currentIndex === windows.length - 1) return state.maxPage + 1;
        const nextIndex = Math.max(0, Math.min(windows.length - 1, currentIndex + (step > 0 ? 1 : -1)));
        return windows[nextIndex].start;
    }

    const targetPageIndex = Math.max(0, Math.min(state.maxPage, currentPage + step));
    const targetWindow = windows.find((window) => targetPageIndex >= window.start && targetPageIndex <= window.end);
    return (targetWindow || windows[windows.length - 1] || { start: 0 }).start;
}

export function getSpreadWindowWithPageShift(targetPage, state) {
    const step = Number(targetPage) || 0;
    const lastPage = Math.max(0, Number(state.maxPage) || 0);
    const displayWindow = state.displayWindow || getDisplayWindow(state.currentPage, state);
    const currentStart = Math.max(0, Math.min(lastPage, Number(displayWindow.start) || 0));
    const nextStart = Math.max(0, Math.min(lastPage, currentStart + step));
    const widePages = state.widePages || new Set();

    if (!state.doublePageMode || nextStart === 0 || nextStart >= lastPage || widePages.has(nextStart)) {
        return { start: nextStart, end: nextStart };
    }

    if (widePages.has(nextStart + 1)) {
        return { start: nextStart, end: nextStart };
    }

    return { start: nextStart, end: nextStart + 1 };
}

export function getSinglePageSpreadWindow(targetPage, state) {
    const step = Number(targetPage) || 0;
    return getSpreadWindowWithPageShift(step > 0 ? 1 : -1, state);
}

// Legacy names retained so mixed cached assets do not fail while clients update.
export function normalizeFirstPageSide(firstPageSide) {
    if (typeof firstPageSide !== "string") {
        return undefined;
    }
    const side = firstPageSide.toUpperCase();
    return ["LEFT", "RIGHT", "UNKNOWN"].includes(side) ? side : undefined;
}

/**
 * Legacy helper for the previous cover-pairing model. The active reader no
 * longer pairs the cover; it uses first-interior-spread windows instead.
 */
export function shouldCoverPairWithFirstPage(mode, firstPageSide) {
    if (mode === "always") {
        return true;
    }
    if (mode === "none") {
        return false;
    }

    const side = normalizeFirstPageSide(firstPageSide);
    if (side === "RIGHT" || side === "UNKNOWN") {
        return true;
    }
    return false;
}

/**
 * Legacy helper for the previous fixed-offset navigation model.
 *
 * @param {number} targetPage signed step requested by navigation (e.g. -1, 1)
 * @param {object} state reader navigation state:
 *   { doublePageMode, showingSinglePage, currentPage, coverPairsWithFirst }
 * @returns {number} the effective signed page offset
 */
export function getPageNavigationOffset(targetPage, state) {
    let offset = targetPage;
    if (state.doublePageMode && !state.showingSinglePage
        && (state.currentPage > 0 || state.coverPairsWithFirst)) {
        offset *= 2;
    }
    return offset;
}

/** Confirm one slide only after a committed ordinary spread in the same direction.
 * Navigation starts invalidate stale/failing requests; archive boundaries and
 * direct jumps never teach a first anchor. Persistence failure does not re-arm.
 */
export function createSpreadFeedback({ persist, commit, onError = () => {} }) {
    let pending = null;
    let generation = 0;
    let sliding = false;
    let inFlight = false;
    const ordinary = (window, state) => Boolean(state.doublePageMode && window
        && window.start > 0 && window.end === window.start + 1 && window.end <= state.maxPage
        && !state.widePages?.has(window.start) && !state.widePages?.has(window.end));
    return {
        cancel() { generation += 1; pending = null; sliding = false; },
        begin({ archiveId, kind = "jump", direction, source, requested, enabled }) {
            generation += 1;
            const token = generation;
            const previous = pending;
            const secondSlide = pending !== null || sliding;
            pending = null;
            sliding = enabled && kind === "slide" && !secondSlide;
            const canArm = sliding;
            return async (target, state) => {
                if (token !== generation) return false;
                sliding = false;
                if (!enabled || !ordinary(source, state) || !ordinary(target, state)
                    || ![-1, 1].includes(direction)) return false;
                const value = inferFirstSpreadStartFromDisplayWindow(target, state);
                if (canArm && target.start === source.start + direction
                    && target.start === requested?.start && target.end === requested?.end && value) {
                    pending = { archiveId, direction, target, value };
                    return false;
                }
                if (kind !== "normal" || !previous || inFlight || previous.archiveId !== archiveId
                    || previous.direction !== direction || previous.target.start !== source.start
                    || previous.target.end !== source.end || target.start !== source.start + direction * 2
                    || value !== previous.value) return false;
                inFlight = true;
                try {
                    await persist(archiveId, value);
                    if (token === generation) commit(archiveId, value);
                    return true;
                } catch (error) {
                    onError(error);
                    return false;
                } finally {
                    inFlight = false;
                }
            };
        },
    };
}
