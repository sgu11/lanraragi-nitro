import assert from "node:assert/strict";
import test from "node:test";

import { createProgressWriteQueue } from "../../public/js/mod/reader-progress.js";

test("progress writes keep a final completion value behind an in-flight page write", async () => {
    const sent = [];
    let releaseFirst;
    let firstStarted;
    const firstStartedPromise = new Promise((resolve) => {
        firstStarted = resolve;
    });
    const firstReleasePromise = new Promise((resolve) => {
        releaseFirst = resolve;
    });

    const queue = createProgressWriteQueue({
        send: async (request) => {
            sent.push(request);
            if (sent.length === 1) {
                firstStarted();
                await firstReleasePromise;
            }
            return { code: 200, data: { success: 1 } };
        },
        wait: async () => {},
    });

    const first = queue.enqueue("archive-1", 9, { endpoint: "/progress/9" });
    await firstStartedPromise;
    const superseded = queue.enqueue("archive-1", 10, { endpoint: "/progress/10" });
    const completionWrite = queue.enqueue("archive-1", 12, {
        endpoint: "/progress/12",
        keepalive: true,
    });

    assert.deepEqual(await superseded, { skipped: true });
    releaseFirst();
    await Promise.all([first, completionWrite]);

    assert.deepEqual(sent.map(({ endpoint, page, keepalive }) => ({ endpoint, page, keepalive })), [
        { endpoint: "/progress/9", page: 9, keepalive: false },
        { endpoint: "/progress/12", page: 12, keepalive: true },
    ]);
});

test("progress writes retry a locked request with the original keepalive flag", async () => {
    const statuses = [423, 423, 200];
    const sent = [];
    const waits = [];
    const queue = createProgressWriteQueue({
        send: async (request) => {
            sent.push(request);
            return { code: statuses.shift(), data: {} };
        },
        wait: async (delayMs) => {
            waits.push(delayMs);
        },
        retryDelayMs: 7,
    });

    const result = await queue.enqueue("archive-1", 0, { keepalive: true });

    assert.equal(result.code, 200);
    assert.equal(sent.length, 3);
    assert.deepEqual(sent.map(({ page, keepalive }) => ({ page, keepalive })), [
        { page: 0, keepalive: true },
        { page: 0, keepalive: true },
        { page: 0, keepalive: true },
    ]);
    assert.deepEqual(waits, [7, 7]);
});

test("a locked older write yields immediately to a newer pending value", async () => {
    const sent = [];
    const waits = [];
    let queue;
    let completionWrite;
    queue = createProgressWriteQueue({
        send: async (request) => {
            sent.push(request);
            if (request.page === 9) {
                completionWrite = queue.enqueue("archive-1", 12, {
                    endpoint: "/progress/12",
                    keepalive: true,
                });
                return { code: 423, data: {} };
            }
            return { code: 200, data: { success: 1 } };
        },
        wait: async (delayMs) => {
            waits.push(delayMs);
        },
    });

    const stale = await queue.enqueue("archive-1", 9, { endpoint: "/progress/9" });
    await completionWrite;

    assert.deepEqual(stale, { skipped: true });
    assert.deepEqual(sent.map(({ page, keepalive }) => ({ page, keepalive })), [
        { page: 9, keepalive: false },
        { page: 12, keepalive: true },
    ]);
    assert.deepEqual(waits, []);
});
