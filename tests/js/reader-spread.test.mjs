import assert from "node:assert/strict";
import test from "node:test";

import {
    buildSpreadWindows,
    getDisplayWindow,
    getPageNavigationDestination,
    getSinglePageSpreadWindow,
    getSpreadWindowWithPageShift,
    getDoublePageInitialProbePages,
    normalizeSpreadStartMode,
    resolveReaderNavigationInput,
    spreadStartFlags,
    shouldPairPageTwoWithThree,
} from "../../public/js/mod/reader-spread.js";

test("page-number jumps stay absolute in manga mode", () => {
    const absoluteMangaNavigation = {
        mangaMode: true,
        respectReadingDirection: false,
    };

    assert.deepEqual(resolveReaderNavigationInput("first", 20, absoluteMangaNavigation), { destination: 0 });
    assert.deepEqual(resolveReaderNavigationInput("last", 20, absoluteMangaNavigation), { destination: 20 });
    assert.deepEqual(resolveReaderNavigationInput(-10, 20, absoluteMangaNavigation), { step: -10 });
    assert.deepEqual(resolveReaderNavigationInput(10, 20, absoluteMangaNavigation), { step: 10 });
});

test("ordinary page turns still follow manga reading direction", () => {
    const directionalMangaNavigation = { mangaMode: true };

    assert.deepEqual(resolveReaderNavigationInput("first", 20, directionalMangaNavigation), { destination: 20 });
    assert.deepEqual(resolveReaderNavigationInput("last", 20, directionalMangaNavigation), { destination: 0 });
    assert.deepEqual(resolveReaderNavigationInput(-1, 20, directionalMangaNavigation), { step: 1 });
    assert.deepEqual(resolveReaderNavigationInput(1, 20, directionalMangaNavigation), { step: -1 });
});

test("legacy spread-start modes normalize to the new first interior spread model", () => {
    assert.equal(normalizeSpreadStartMode("always"), "pair2");
    assert.equal(normalizeSpreadStartMode("none"), "pair2");
    assert.equal(normalizeSpreadStartMode("pair3"), "auto");
    assert.equal(normalizeSpreadStartMode("bogus"), "auto");
});

test("spreadStartFlags maps manual and adaptive modes to first interior spread", () => {
    assert.deepEqual(spreadStartFlags("pair2", "4"), { firstSpreadStart: 2 });
    assert.deepEqual(spreadStartFlags("pair3", "2"), { firstSpreadStart: 2 });
    assert.deepEqual(spreadStartFlags("auto", "2"), { firstSpreadStart: 2 });
    assert.deepEqual(spreadStartFlags("auto", "4"), { firstSpreadStart: 4 });
    assert.deepEqual(spreadStartFlags("auto", "3"), { firstSpreadStart: 4 });
    assert.deepEqual(spreadStartFlags("auto", "UNKNOWN"), { firstSpreadStart: 2 });
    assert.deepEqual(spreadStartFlags("auto", undefined), { firstSpreadStart: 2 });
});

test("manual and adaptive modes decide whether page 2 pairs with page 3", () => {
    assert.equal(shouldPairPageTwoWithThree("pair2", "4"), true);
    assert.equal(shouldPairPageTwoWithThree("pair3", "2"), true);
    assert.equal(shouldPairPageTwoWithThree("auto", "2"), true);
    assert.equal(shouldPairPageTwoWithThree("auto", "4"), false);
    assert.equal(shouldPairPageTwoWithThree("auto", undefined), true);
});

test("cover is always single and pair2 starts interior spreads at page 2", () => {
    assert.deepEqual(buildSpreadWindows(6, {
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set(),
    }), [
        { start: 0, end: 0 },
        { start: 1, end: 2 },
        { start: 3, end: 4 },
        { start: 5, end: 6 },
    ]);
});

test("adaptive offset anchored on page 4 keeps page 2 single before pairing page 3 with page 4", () => {
    assert.deepEqual(buildSpreadWindows(6, {
        doublePageMode: true,
        firstSpreadStart: 4,
        widePages: new Set(),
    }), [
        { start: 0, end: 0 },
        { start: 1, end: 1 },
        { start: 2, end: 3 },
        { start: 4, end: 5 },
        { start: 6, end: 6 },
    ]);
});

test("wide pages are single and following pages resume pairing", () => {
    assert.deepEqual(buildSpreadWindows(7, {
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set([3]),
    }), [
        { start: 0, end: 0 },
        { start: 1, end: 2 },
        { start: 3, end: 3 },
        { start: 4, end: 5 },
        { start: 6, end: 7 },
    ]);
});

test("buildSpreadWindows is memoized on its inputs and rebuilds only on change", () => {
    const state = {
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set(),
    };

    // Repeated calls with identical inputs must return the cached array
    // reference (no O(maxPage) rebuild) — the optimization that makes the
    // double-page turn path scale with the changing viewport, not pagecount.
    const first = buildSpreadWindows(50, state);
    const second = buildSpreadWindows(50, state);
    assert.equal(second, first, "identical inputs return the cached array reference");

    // Any of the four signature inputs changing must rebuild.
    const afterMaxPage = buildSpreadWindows(60, state);
    assert.notEqual(afterMaxPage, first, "changed maxPage rebuilds");

    const afterDoubleModeOff = buildSpreadWindows(60, { ...state, doublePageMode: false });
    assert.notEqual(afterDoubleModeOff, afterMaxPage, "changed doublePageMode rebuilds");

    const afterWidePages = buildSpreadWindows(60, { ...state, widePages: new Set([3]) });
    assert.notEqual(afterWidePages, afterDoubleModeOff, "changed widePages rebuilds");

    // widePages equality is by content, not identity: a new Set with the same
    // members must still hit the cache.
    const sameWidePages = buildSpreadWindows(60, { ...state, widePages: new Set([3]) });
    assert.equal(sameWidePages, afterWidePages, "new Set with same members hits the cache");
});

test("display lookup normalizes a page inside a spread to the spread start", () => {
    assert.deepEqual(getDisplayWindow(2, {
        maxPage: 6,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set(),
    }), { start: 1, end: 2 });
});

test("navigation follows display windows instead of fixed offsets", () => {
    const state = {
        maxPage: 7,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set([3]),
    };

    assert.equal(getPageNavigationDestination(1, { ...state, currentPage: 0 }), 1);
    assert.equal(getPageNavigationDestination(1, { ...state, currentPage: 1 }), 3);
    assert.equal(getPageNavigationDestination(1, { ...state, currentPage: 3 }), 4);
    assert.equal(getPageNavigationDestination(-1, { ...state, currentPage: 4 }), 3);
    assert.equal(getPageNavigationDestination(10, { ...state, currentPage: 1 }), 6);
    assert.equal(getPageNavigationDestination(-10, { ...state, currentPage: 4 }), 0);
    assert.equal(getPageNavigationDestination(-1, { ...state, doublePageMode: false, currentPage: 0 }), -1);
    assert.equal(getPageNavigationDestination(1, { ...state, doublePageMode: false, currentPage: 7 }), 8);

    const doublePageState = { ...state, doublePageMode: true };
    assert.equal(getPageNavigationDestination(-1, { ...doublePageState, currentPage: 0 }), -1);
    assert.equal(getPageNavigationDestination(1, { ...doublePageState, currentPage: 6 }), 8);
});

test("double-page cover navigation only probes the cover before rendering", () => {
    assert.deepEqual(getDoublePageInitialProbePages(0, 20), [0]);
    assert.deepEqual(getDoublePageInitialProbePages(5, 20), [5, 4, 6]);
    assert.deepEqual(getDoublePageInitialProbePages(20, 20), [20, 19]);
});

test("double-page probe pages are loaded concurrently, not serially awaited", async () => {
    const { readFile } = await import("node:fs/promises");
    const readerSrc = await readFile(new URL("../../public/js/mod/reader_common.js", import.meta.url), "utf8");

    // The probe pages don't depend on each other (they only populate
    // preloadedDimensions for wide-page detection), so they must be loaded
    // via Promise.all rather than a serial await loop. Each probe writes to
    // distinct preloadedDimensions/preloadedPromises keys, so concurrent
    // loadImage calls are safe.
    assert.match(
        readerSrc,
        /await Promise\.all\(\s*getDoublePageInitialProbePages\([\s\S]*?\.map\([\s\S]*?loadImage/,
        "double-page probe should use Promise.all over getDoublePageInitialProbePages().map(loadImage)"
    );
    // The old serial form must be gone.
    assert.doesNotMatch(
        readerSrc,
        /for \(const probePage of getDoublePageInitialProbePages[^)]*\)\s*\{\s*await loadImage\(probePage\)/,
        "serial double-page probe loop should be replaced with Promise.all"
    );
});

test("single-page spread sliding allows overlapping double-page windows", () => {
    const state = {
        maxPage: 8,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set(),
    };

    assert.deepEqual(getSinglePageSpreadWindow(-1, {
        ...state,
        displayWindow: { start: 3, end: 4 },
    }), { start: 2, end: 3 });
    assert.deepEqual(getSinglePageSpreadWindow(1, {
        ...state,
        displayWindow: { start: 4, end: 5 },
    }), { start: 5, end: 6 });
});

test("single-page spread sliding keeps cover and wide pages single", () => {
    const state = {
        maxPage: 8,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set([5, 7]),
    };

    assert.deepEqual(getSinglePageSpreadWindow(-1, {
        ...state,
        displayWindow: { start: 1, end: 2 },
    }), { start: 0, end: 0 });
    assert.deepEqual(getSinglePageSpreadWindow(1, {
        ...state,
        displayWindow: { start: 4, end: 4 },
    }), { start: 5, end: 5 });
    assert.deepEqual(getSinglePageSpreadWindow(1, {
        ...state,
        displayWindow: { start: 5, end: 5 },
    }), { start: 6, end: 6 });
});

test("shifted spread navigation keeps a double-page stride from an overlapping spread", () => {
    const state = {
        maxPage: 10,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set(),
        displayWindow: { start: 4, end: 5 },
    };

    assert.deepEqual(getSpreadWindowWithPageShift(2, state), { start: 6, end: 7 });
    assert.deepEqual(getSpreadWindowWithPageShift(-2, state), { start: 2, end: 3 });
});

test("shifted spread navigation keeps wide pages single", () => {
    const state = {
        maxPage: 10,
        doublePageMode: true,
        firstSpreadStart: 2,
        widePages: new Set([6, 9]),
        displayWindow: { start: 4, end: 5 },
    };

    assert.deepEqual(getSpreadWindowWithPageShift(2, state), { start: 6, end: 6 });
    assert.deepEqual(getSpreadWindowWithPageShift(4, state), { start: 8, end: 8 });
});
