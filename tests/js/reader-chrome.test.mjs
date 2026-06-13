import assert from "node:assert/strict";
import test from "node:test";

import {
    getFitHeightViewportPercent,
    isReaderMinimalChrome,
    shouldWheelNavigatePages,
} from "../../public/js/mod/reader-chrome.js";

test("minimal chrome is active for infinite scroll or hidden header", () => {
    assert.equal(isReaderMinimalChrome(false, false), false);
    assert.equal(isReaderMinimalChrome(true, false), true);
    assert.equal(isReaderMinimalChrome(false, true), true);
    assert.equal(isReaderMinimalChrome(true, true), true);
});

test("fit-height percent reflects visible reader chrome", () => {
    assert.equal(getFitHeightViewportPercent(false, false), 90);
    assert.equal(getFitHeightViewportPercent(true, false), 98);
    assert.equal(getFitHeightViewportPercent(false, true), 100);
    assert.equal(getFitHeightViewportPercent(true, true), 98);
});

test("wheel navigation follows fullscreen and hidden-header paginated modes", () => {
    assert.equal(shouldWheelNavigatePages({
        infiniteScroll: false,
        fullscreen: false,
        headerHidden: false,
    }), false);
    assert.equal(shouldWheelNavigatePages({
        infiniteScroll: false,
        fullscreen: true,
        headerHidden: false,
    }), true);
    assert.equal(shouldWheelNavigatePages({
        infiniteScroll: false,
        fullscreen: false,
        headerHidden: true,
    }), true);
    assert.equal(shouldWheelNavigatePages({
        infiniteScroll: true,
        fullscreen: true,
        headerHidden: true,
    }), false);
});
