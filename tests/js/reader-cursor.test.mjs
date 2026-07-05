import assert from "node:assert/strict";
import test from "node:test";

import {
    beginReaderNavigation,
    commitReaderNavigation,
    consumeQueuedReaderNavigationStep,
    createReaderCursor,
    isReaderNavigationPending,
    queueReaderNavigationStep,
    selectReaderOpeningPage,
} from "../../public/js/mod/reader-spread.js";

test("reader cursor rejects stale async navigation commits", () => {
    const cursor = createReaderCursor(0);
    const first = beginReaderNavigation(cursor, 5, 20);
    const second = beginReaderNavigation(cursor, 6, 20);

    assert.equal(commitReaderNavigation(cursor, first.token, 5, 20), false);
    assert.equal(cursor.displayPage, 0);

    assert.equal(commitReaderNavigation(cursor, second.token, 6, 20), true);
    assert.equal(cursor.displayPage, 6);
    assert.equal(isReaderNavigationPending(cursor), false);
});

test("reader cursor coalesces rapid relative input while a render is pending", () => {
    const cursor = createReaderCursor(0);
    beginReaderNavigation(cursor, 0, 20);

    for (let i = 0; i < 10; i += 1) {
        queueReaderNavigationStep(cursor, 1, { resetAuto: true });
    }

    assert.equal(cursor.displayPage, 0);
    assert.deepEqual(consumeQueuedReaderNavigationStep(cursor), {
        step: 1,
        resetAuto: true,
    });
    assert.equal(consumeQueuedReaderNavigationStep(cursor), null);
});

test("reader cursor preserves queued jump magnitude while a render is pending", () => {
    const cursor = createReaderCursor(0);
    beginReaderNavigation(cursor, 0, 20);

    assert.equal(queueReaderNavigationStep(cursor, 10, { resetAuto: true }), true);

    assert.deepEqual(consumeQueuedReaderNavigationStep(cursor), {
        step: 10,
        resetAuto: true,
    });
});

test("reader opening page treats synced progress as a library-open hint only", () => {
    assert.deepEqual(selectReaderOpeningPage({
        explicitPage: 4,
        progressPage: 10,
        progressEnabled: true,
        userInteractedBeforeInitialPageScroll: false,
        maxPage: 20,
    }), { page: 4, reason: "explicit-page" });

    assert.deepEqual(selectReaderOpeningPage({
        explicitPage: null,
        progressPage: 10,
        progressEnabled: true,
        userInteractedBeforeInitialPageScroll: false,
        maxPage: 20,
    }), { page: 10, reason: "resume-progress" });

    assert.deepEqual(selectReaderOpeningPage({
        explicitPage: null,
        progressPage: 10,
        progressEnabled: false,
        userInteractedBeforeInitialPageScroll: false,
        maxPage: 20,
    }), { page: 0, reason: "default-first" });
});
