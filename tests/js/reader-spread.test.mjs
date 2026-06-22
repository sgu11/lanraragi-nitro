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
    spreadStartFlags,
    shouldPairPageTwoWithThree,
} from "../../public/js/mod/reader-spread.js";

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
});

test("double-page cover navigation only probes the cover before rendering", () => {
    assert.deepEqual(getDoublePageInitialProbePages(0, 20), [0]);
    assert.deepEqual(getDoublePageInitialProbePages(5, 20), [5, 4, 6]);
    assert.deepEqual(getDoublePageInitialProbePages(20, 20), [20, 19]);
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
