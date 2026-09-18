import assert from "node:assert/strict";
import test from "node:test";
import { createReaderImageLoader } from "../../public/js/mod/reader-image-loader.js";

function harness(options = {}) {
    const requests = [];
    const created = [];
    const revoked = [];
    const loader = createReaderImageLoader({
        fetchImage: (src, config) => new Promise((resolve) => requests.push({ src, config, resolve })),
        urls: {
            createObjectURL: () => { const src = `blob:${created.length}`; created.push(src); return src; },
            revokeObjectURL: (src) => revoked.push(src),
        },
        ...options,
    });
    function respond(index = 0) {
        requests[index].resolve({ ok: true, blob: async () => ({ size: 2048 }) });
    }
    return { loader, requests, created, revoked, respond };
}

test("invalidation aborts inflight work and rejects even when fetch ignores abort", async () => {
    const h = harness();
    const loading = h.loader.bytes(0, "/old");
    h.loader.invalidate();
    assert.equal(h.requests[0].config.signal.aborted, true);
    h.respond();
    await assert.rejects(loading, { name: "AbortError" });
    assert.deepEqual(h.created, []);
    assert.deepEqual(h.loader.dimensions, {});
    assert.deepEqual(h.loader.sizes, {});
});

test("late completion cannot remove a new generation's request for the same URL", async () => {
    const h = harness();
    const old = h.loader.bytes(0, "/page");
    h.loader.invalidate();
    const current = h.loader.bytes(0, "/page");
    h.respond(0);
    await assert.rejects(old, { name: "AbortError" });
    const duplicate = h.loader.bytes(0, "/page");
    assert.equal(h.requests.length, 2);
    h.respond(1);
    assert.deepEqual(await duplicate, await current);
    assert.equal(h.loader.sizes[0], 2);
});

test("fallback aliases share ownership; eviction and dispose revoke each Blob once", async () => {
    const h = harness({ getLimit: () => 2 });
    const p = h.loader.bytes(0, "/original"); h.respond();
    const original = await p;
    h.loader.alias("/crop", original);
    const next = h.loader.bytes(1, "/next"); h.respond(1); await next;
    assert.equal(h.loader.has("/original"), false);
    assert.equal(h.loader.has("/crop"), true);
    assert.deepEqual(h.revoked, []);
    h.loader.dispose();
    assert.deepEqual(h.revoked.sort(), h.created.sort());
    h.loader.dispose();
    assert.equal(h.revoked.length, 2);
});

test("invalidation cancels browser image probes and prevents stale dimensions", async () => {
    const images = [];
    const h = harness({ makeImage: () => {
        const image = { removeAttribute: () => {}, naturalWidth: 100, naturalHeight: 200 };
        images.push(image); return image;
    } });
    const p = h.loader.load(0, "/page", "browser");
    h.loader.invalidate();
    await assert.rejects(p, { name: "AbortError" });
    assert.equal(images[0].onload, null);
    assert.deepEqual(h.loader.dimensions, {});
});

test("a previously returned image cannot enter the new generation's decode cache", async () => {
    const h = harness();
    const p = h.loader.bytes(0, "/page"); h.respond();
    const loaded = await p;
    h.loader.invalidate();
    await assert.rejects(h.loader.decode(loaded), { name: "AbortError" });
    assert.throws(() => h.loader.alias("/crop", loaded), { name: "AbortError" });
});

test("new bytes remain usable while the previous displayed image protects the cache", async () => {
    const displayed = new Set();
    const h = harness({ getLimit: () => 1, getDisplayedSources: () => displayed });
    const first = h.loader.bytes(0, "/first"); h.respond();
    displayed.add((await first).src);
    const next = h.loader.bytes(1, "/next"); h.respond(1);
    const entry = await next;
    assert.equal(h.loader.has("/next"), true);
    assert.equal(h.revoked.includes(entry.src), false);
    displayed.clear();
    h.loader.prune();
    assert.equal(h.loader.has("/first"), false);
    assert.equal(h.loader.has("/next"), true);
});

test("decoded LRU keeps recent images and releases old bytes after eviction", async () => {
    const h = harness({ getLimit: () => 1, maxDecoded: 1 });
    const first = h.loader.bytes(0, "/first"); h.respond();
    const a = await first;
    const image = { naturalWidth: 100, naturalHeight: 200 };
    assert.equal(await h.loader.decode({ ...a, image }), image);
    const next = h.loader.bytes(1, "/next"); h.respond(1);
    const b = await next;
    await h.loader.decode({ ...b, image: {} });
    h.loader.prune();
    assert.deepEqual(h.revoked, [a.src]);
    assert.equal(h.loader.has("/next"), true);
});

test("loaded probes await real decode, share it, and retry a failed decode", async () => {
    const h = harness();
    let complete;
    let calls = 0;
    const image = { decode: () => { calls++; return new Promise(resolve => { complete = resolve; }); } };
    const loaded = { src: "/ready", generation: 0, image };
    let ready = false;
    const first = h.loader.decode(loaded).then(result => { ready = true; return result; });
    const second = h.loader.decode(loaded);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(calls, 1);
    assert.equal(ready, false);
    complete();
    assert.equal(await first, image);
    assert.equal(await second, image);
    await h.loader.decode(loaded);
    assert.equal(calls, 1);
    const broken = { src: "/broken", image: { decode: async () => { throw new Error("decode failed"); } } };
    await assert.rejects(h.loader.decode(broken), /decode failed/);
    const retryImage = { decode: async () => {} };
    assert.equal(await h.loader.decode({ src: "/broken", image: retryImage }), retryImage);
});

test("invalidation during decode rejects late completion", async () => {
    const h = harness();
    let complete;
    const loading = h.loader.decode({ src: "/page", image: { decode: () => new Promise(resolve => { complete = resolve; }) } });
    await new Promise(resolve => setImmediate(resolve));
    h.loader.invalidate();
    complete();
    await assert.rejects(loading, { name: "AbortError" });
});

test("current byte window survives late out-of-window fetch completions", async () => {
    let windowSources = new Set(["/next-a", "/next-b"]);
    const h = harness({ getLimit: () => 2, getProtectedSources: () => windowSources });
    const a = h.loader.bytes(0, "/next-a"); h.respond(); await a;
    const b = h.loader.bytes(1, "/next-b"); h.respond(1); await b;
    const stale = h.loader.bytes(9, "/stale"); h.respond(2); await stale;
    h.loader.prune();
    assert.equal(h.loader.has("/next-a"), true);
    assert.equal(h.loader.has("/next-b"), true);
    assert.equal(h.loader.has("/stale"), false);
    windowSources = new Set();
    h.loader.dispose();
    assert.equal(h.revoked.length, 3);
});

test("navigation outside the preload window pins bytes while its shared probe loads", async () => {
    const images = [];
    const h = harness({ getLimit: () => 1, makeImage: () => {
        const image = { naturalWidth: 100, naturalHeight: 200 };
        images.push(image);
        return image;
    } });
    const target = h.loader.load(20, "/jump");
    const duplicate = h.loader.load(20, "/jump");
    h.respond();
    await new Promise(resolve => setImmediate(resolve));
    const stale = h.loader.bytes(1, "/old-preload"); h.respond(1); await stale;
    assert.equal(h.loader.has("/jump"), true);
    assert.equal(h.revoked.includes("blob:0"), false);
    assert.equal(images.length, 1);
    images[0].onload();
    assert.equal((await target).image, (await duplicate).image);
    h.loader.dispose();
    assert.equal(h.revoked.length, 2);
});

test("pending decodes stay shared when the LRU count is exceeded", async () => {
    const h = harness({ maxDecoded: 1 });
    let finish; let calls = 0;
    const slow = { src: "/slow", image: { decode: () => { calls++; return new Promise(resolve => { finish = resolve; }); } } };
    const first = h.loader.decode(slow);
    await new Promise(resolve => setImmediate(resolve));
    await h.loader.decode({ src: "/other", image: {} });
    const duplicate = h.loader.decode(slow);
    finish(); await Promise.all([first, duplicate]);
    assert.equal(calls, 1);
});

test("pixel budget evicts decoded images but preserves the previous display", async () => {
    const retained = new Set(["/previous"]);
    const h = harness({ maxDecoded: 8, maxDecodedBytes: 800, getRetainedSources: () => retained });
    const calls = {};
    const loaded = src => ({ src, image: { naturalWidth: 10, naturalHeight: 10, decode: async () => { calls[src] = (calls[src] || 0) + 1; } } });
    const previous = loaded("/previous"), next = loaded("/next"), distant = loaded("/distant");
    await h.loader.decode(previous); await h.loader.decode(next); await h.loader.decode(distant);
    await h.loader.decode(previous); assert.equal(calls["/previous"], 1);
    await h.loader.decode(next); assert.equal(calls["/next"], 2);
    retained.clear(); h.loader.prune();
});
