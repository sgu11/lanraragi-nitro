/**
 * Pure double-page "spread-start" logic for the reader. No DOM or browser
 * globals, so it can be unit tested directly under `node --test`
 * (see tests/js/reader-spread.test.mjs).
 *
 * Spread-start modes:
 *   "auto"   - use server-detected first page side
 *   "always" - pair the cover (page 0) with page 1 (cover + first)
 *   "none"   - cover shown alone
 */

export function normalizeFirstPageSide(firstPageSide) {
    if (typeof firstPageSide !== "string") {
        return undefined;
    }
    const side = firstPageSide.toUpperCase();
    return ["LEFT", "RIGHT", "UNKNOWN"].includes(side) ? side : undefined;
}

/**
 * In auto mode, LEFT or still-pending detection keeps the cover alone. RIGHT
 * and UNKNOWN pair the cover with page 1, matching Suwayomi's adaptive offset
 * semantics while preserving the user's manual overrides.
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

/** Derive the reader's spread flags from a spread-start mode and detection. */
export function spreadStartFlags(mode, firstPageSide) {
    return {
        coverPairsWithFirst: shouldCoverPairWithFirstPage(mode, firstPageSide),
    };
}

/**
 * How many pages a navigation step actually moves, accounting for double-page
 * mode. In double-page mode a step is doubled after the cover. The cover step
 * is doubled only when the current spread-start state pairs page 0 with page 1.
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
