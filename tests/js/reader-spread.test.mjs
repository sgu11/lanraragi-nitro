import assert from "node:assert/strict";
import test from "node:test";

import {
    spreadStartFlags,
    shouldCoverPairWithFirstPage,
    getPageNavigationOffset,
} from "../../public/js/mod/reader-spread.js";

test("spreadStartFlags maps manual and adaptive modes to cover pairing", () => {
    assert.deepEqual(spreadStartFlags("always", "LEFT"), { coverPairsWithFirst: true });
    assert.deepEqual(spreadStartFlags("none", "RIGHT"), { coverPairsWithFirst: false });
    assert.deepEqual(spreadStartFlags("auto", "LEFT"), { coverPairsWithFirst: false });
    assert.deepEqual(spreadStartFlags("auto", "RIGHT"), { coverPairsWithFirst: true });
    assert.deepEqual(spreadStartFlags("auto", "UNKNOWN"), { coverPairsWithFirst: true });
    assert.deepEqual(spreadStartFlags("auto", undefined), { coverPairsWithFirst: false });
});

test("adaptive pairing treats LEFT or pending detection as cover-alone", () => {
    assert.equal(shouldCoverPairWithFirstPage("auto", "LEFT"), false);
    assert.equal(shouldCoverPairWithFirstPage("auto", undefined), false);
    assert.equal(shouldCoverPairWithFirstPage("auto", null), false);
});

test("adaptive pairing treats RIGHT or UNKNOWN detection as cover+first", () => {
    assert.equal(shouldCoverPairWithFirstPage("auto", "RIGHT"), true);
    assert.equal(shouldCoverPairWithFirstPage("auto", "UNKNOWN"), true);
});

const navState = (over) => ({
    doublePageMode: true,
    showingSinglePage: false,
    currentPage: 2,
    coverPairsWithFirst: false,
    mangaMode: false,
    ...over,
});

test("double-page navigation doubles after the cover in spread mode", () => {
    assert.equal(getPageNavigationOffset(1, navState({})), 2);
    assert.equal(getPageNavigationOffset(-1, navState({})), -2);
});

test("single-page view is never doubled", () => {
    assert.equal(getPageNavigationOffset(1, navState({ showingSinglePage: true })), 1);
});

test("cover view is not doubled unless adaptive pairing pairs it with page 1", () => {
    assert.equal(getPageNavigationOffset(1, navState({ currentPage: 0 })), 1);
    assert.equal(getPageNavigationOffset(1, navState({ currentPage: 0, coverPairsWithFirst: true })), 2);
});
