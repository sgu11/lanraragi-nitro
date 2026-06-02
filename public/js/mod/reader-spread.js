/**
 * Pure double-page "spread-start" logic for the reader, including the
 * first-portrait-page dampener. No DOM or browser globals, so it can be unit
 * tested directly under `node --test` (see tests/js/reader-spread.test.mjs).
 *
 * Spread-start modes:
 *   "auto"   — cover shown alone; dampen the first portrait page after the cover
 *   "always" — pair the cover (page 0) with page 1 (cover + first)
 *   "none"   — cover shown alone; no dampener
 */

/** Derive the reader's spread flags from a spread-start mode. */
export function spreadStartFlags(mode) {
    return {
        doublePageOffset: mode === "always",
        firstPortraitPageDamper: mode === "auto",
    };
}

/** A page is "portrait" when it is taller than it is wide. */
export function isPortraitPage(dimensions) {
    return !!dimensions && dimensions.height > dimensions.width;
}

/**
 * The dampener protects only the page right after the cover (index 1) when it
 * is portrait and "auto" mode enabled the dampener.
 */
export function shouldUseFirstPortraitPageDamper(damperEnabled, pageIndex, dimensions) {
    return !!damperEnabled && pageIndex === 1 && isPortraitPage(dimensions);
}

/**
 * How many pages a navigation step actually moves, accounting for double-page
 * mode and the first-portrait-page dampener. In double-page mode a step is
 * doubled, except when stepping toward the cover would cross a dampened first
 * portrait page — then the step collapses back to a single page so the portrait
 * page is not skipped.
 *
 * @param {number} targetPage signed step requested by navigation (e.g. -1, 1)
 * @param {object} state reader navigation state:
 *   { doublePageMode, showingSinglePage, currentPage, doublePageOffset,
 *     mangaMode, firstPortraitPageDamper, firstPageDimensions }
 * @returns {number} the effective signed page offset
 */
export function getPageNavigationOffset(targetPage, state) {
    let offset = targetPage;
    if (state.doublePageMode && !state.showingSinglePage
        && (state.currentPage > 0 || state.doublePageOffset)) {
        offset *= 2;
        const movesTowardCover = state.mangaMode ? targetPage > 0 : targetPage < 0;
        if (movesTowardCover && state.currentPage === 2
            && shouldUseFirstPortraitPageDamper(state.firstPortraitPageDamper, 1, state.firstPageDimensions)) {
            offset = targetPage;
        }
    }
    return offset;
}
