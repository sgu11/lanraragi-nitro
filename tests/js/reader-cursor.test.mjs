import assert from "node:assert/strict";
import test from "node:test";

import {
    beginReaderNavigation,
    commitReaderNavigation,
    consumeQueuedReaderNavigationStep,
    createReaderCursor,
    getSyncedReadingProgressPage,
    getSyncedReadingProgressPageForDisplayWindow,
    isReaderNavigationPending,
    queueReaderNavigationStep,
    selectReaderOpeningPage,
} from "../../public/js/mod/reader-spread.js";

test("reader preserves completed synced progress after the final page is reached", () => {
    assert.equal(getSyncedReadingProgressPage(1, 20), 1);
    assert.equal(getSyncedReadingProgressPage(19, 20), 19);
    assert.equal(getSyncedReadingProgressPage(20, 20), 20);
    assert.equal(getSyncedReadingProgressPage(21, 20), 20);
});

test("reader preserves completed progress from the visible end of a double-page window", () => {
    const currentPage = 8;
    const ordinaryProgressPage = currentPage + 1;
    const visibleWindow = { start: 8, end: 9 };

    assert.equal(ordinaryProgressPage, 9);
    assert.equal(getSyncedReadingProgressPageForDisplayWindow(visibleWindow, 10), 10);
    assert.equal(getSyncedReadingProgressPageForDisplayWindow({ start: 6, end: 7 }, 10), 8);
});

test("completed progress remains read while a later Library open starts at page one", () => {
    const pageCount = 20;
    const maxPage = pageCount - 1;
    const persistedProgress = getSyncedReadingProgressPage(pageCount, pageCount);

    assert.ok((persistedProgress / pageCount) > 0.85);
    assert.deepEqual(selectReaderOpeningPage({
        progressPage: persistedProgress - 1,
        progressEnabled: true,
        maxPage,
    }), { page: 0, reason: "default-first" });
});

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

    assert.deepEqual(selectReaderOpeningPage({
        explicitPage: null,
        progressPage: 20,
        progressEnabled: true,
        userInteractedBeforeInitialPageScroll: false,
        maxPage: 20,
    }), { page: 0, reason: "default-first" });
});
