import assert from "node:assert/strict";
import test from "node:test";
import { createReaderPreloadQueue } from "../../public/js/mod/reader-image-loader.js";
const drain = () => new Promise(resolve => setImmediate(resolve));

test("pixel and concurrency limits bound speculative work across batches", async () => {
    const queue = createReaderPreloadQueue({ concurrency: 2, pixelLimit: 100 });
    const started = [], finish = [];
    const promises = [150, 40, 40, 40].map((pixels, i) => queue.schedule(() => {
        started.push(i); return new Promise(resolve => finish[i] = resolve);
    }, { pixels }));
    await drain(); assert.deepEqual(started, [0]);
    finish[0](); await drain(); assert.deepEqual(started, [0, 1, 2]);
    finish[1](); await drain(); assert.deepEqual(started, [0, 1, 2, 3]);
    finish[2](); finish[3](); await Promise.all(promises);
});

test("clear resolves queued work and stale work never starts", async () => {
    const queue = createReaderPreloadQueue({ concurrency: 1 });
    let finish, current = true; let calls = 0;
    const first = queue.schedule(() => new Promise(resolve => finish = resolve));
    const old = queue.schedule(() => { calls++; });
    await drain(); queue.clear(); await old;
    const stale = queue.schedule(() => { calls++; }, { isCurrent: () => current });
    current = false; finish(); await Promise.all([first, stale]);
    assert.equal(calls, 0);
    await assert.rejects(queue.schedule(() => { throw new Error("probe failed"); }), /probe failed/);
    assert.equal(await queue.schedule(() => 42), 42);
});
