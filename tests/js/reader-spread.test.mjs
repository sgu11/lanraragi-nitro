import assert from "node:assert/strict";
import test from "node:test";

import {
    spreadStartFlags,
    isPortraitPage,
    shouldUseFirstPortraitPageDamper,
    getPageNavigationOffset,
} from "../../public/js/mod/reader-spread.js";

const PORTRAIT = { width: 900, height: 1400 };
const LANDSCAPE = { width: 1400, height: 900 };
const SQUARE = { width: 1000, height: 1000 };

test("spreadStartFlags maps auto/none/always to the correct flags", () => {
    assert.deepEqual(spreadStartFlags("auto"), { doublePageOffset: false, firstPortraitPageDamper: true });
    assert.deepEqual(spreadStartFlags("none"), { doublePageOffset: false, firstPortraitPageDamper: false });
    assert.deepEqual(spreadStartFlags("always"), { doublePageOffset: true, firstPortraitPageDamper: false });
});

test("isPortraitPage is true only for taller-than-wide pages", () => {
    assert.equal(isPortraitPage(PORTRAIT), true);
    assert.equal(isPortraitPage(LANDSCAPE), false);
    assert.equal(isPortraitPage(SQUARE), false);
    assert.equal(isPortraitPage(undefined), false);
});

test("dampener applies only to the portrait page right after the cover, when enabled", () => {
    assert.equal(shouldUseFirstPortraitPageDamper(true, 1, PORTRAIT), true);
    assert.equal(shouldUseFirstPortraitPageDamper(true, 0, PORTRAIT), false);
    assert.equal(shouldUseFirstPortraitPageDamper(true, 2, PORTRAIT), false);
    assert.equal(shouldUseFirstPortraitPageDamper(true, 1, LANDSCAPE), false);
    assert.equal(shouldUseFirstPortraitPageDamper(true, 1, SQUARE), false);
    assert.equal(shouldUseFirstPortraitPageDamper(true, 1, undefined), false);
    assert.equal(shouldUseFirstPortraitPageDamper(false, 1, PORTRAIT), false);
});

const navState = (over) => ({
    doublePageMode: true,
    showingSinglePage: false,
    currentPage: 2,
    doublePageOffset: false,
    mangaMode: false,
    firstPortraitPageDamper: false,
    firstPageDimensions: undefined,
    ...over,
});

test("auto-mode dampener shortens the first double spread step back to a single page", () => {
    const state = navState({ firstPortraitPageDamper: true, firstPageDimensions: PORTRAIT });
    assert.equal(getPageNavigationOffset(-1, state), -1);
});

test("none mode keeps the full double-page back step", () => {
    const state = navState({ firstPageDimensions: PORTRAIT }); // damper disabled
    assert.equal(getPageNavigationOffset(-1, state), -2);
});

test("dampener does not shorten manga-mode navigation away from the cover", () => {
    const state = navState({ mangaMode: true, firstPortraitPageDamper: true, firstPageDimensions: PORTRAIT });
    assert.equal(getPageNavigationOffset(-1, state), -2); // backward in manga moves away from cover
    assert.equal(getPageNavigationOffset(1, state), 1);   // forward in manga moves toward cover → shortened
});

test("double-page doubling stays for always and none modes", () => {
    assert.equal(getPageNavigationOffset(1, navState({ doublePageOffset: true })), 2); // always
    assert.equal(getPageNavigationOffset(1, navState({})), 2);                         // none
});

test("single-page view is never doubled", () => {
    assert.equal(getPageNavigationOffset(1, navState({ showingSinglePage: true })), 1);
});

test("cover view (page 0) is not doubled unless offset pairs it with page 1", () => {
    assert.equal(getPageNavigationOffset(1, navState({ currentPage: 0 })), 1);
    assert.equal(getPageNavigationOffset(1, navState({ currentPage: 0, doublePageOffset: true })), 2);
});
