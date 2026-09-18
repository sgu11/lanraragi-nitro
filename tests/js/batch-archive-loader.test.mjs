import assert from "node:assert/strict";
import test from "node:test";
import { createBatchArchiveLoader, validBatchSelection } from "../../public/js/mod/batch-archive-loader.js";
const id = (n) => n.toString(16).padStart(40, "0");
const tick = () => new Promise((resolve) => setImmediate(resolve));
function harness(request, options = {}) {
    const published = [], errors = [], completed = [];
    const loader = createBatchArchiveLoader({ request, publish: (...args) => published.push(args),
        failed: (error) => errors.push(error), complete: () => completed.push(true), ...options });
    return { loader, published, errors, completed };
}

test("selection validates IDs and deduplicates direct and overlapping Tankoubon members before fetching", async () => {
    const requests = [];
    const h = harness(async (url) => { requests.push(url); return url.includes("tankoubons")
        ? { archives: [id(1), id(2), id(2), null, "invalid"] } : { arcid: url.split("/")[3] }; });
    await h.loader.load([null, {}, id(1), id(1), "TANK_1", "TANK_1"]);
    assert.equal(requests.length, 3); assert.equal(h.published[0][0].length, 2);
    assert.deepEqual(validBatchSelection("invalid"), []);
});

test("metadata requests are bounded and a replacement load stops scheduling old work", async () => {
    const pending = [];
    const h = harness((url) => new Promise((resolve) => pending.push({ url, resolve })), { concurrency: 3 });
    const old = h.loader.load(Array.from({ length: 30 }, (_, n) => id(n + 1)));
    await tick(); assert.equal(pending.length, 3);
    const fresh = h.loader.load([id(99)]); await tick(); assert.equal(pending.length, 4);
    pending[3].resolve({ arcid: id(99) }); await fresh;
    pending.slice(0, 3).forEach((p, n) => p.resolve({ arcid: id(n + 1) })); await old;
    assert.equal(pending.length, 4); assert.equal(h.published.length, 1);
    assert.equal(h.published[0][0][0].arcid, id(99)); assert.equal(h.completed.length, 1);
});

test("individual failures retain available archives, report once and finish the spinner", async () => {
    const h = harness(async (url) => {
        if (url.includes("tankoubons") || url.includes(id(2))) throw new Error("fixture failure");
        return { arcid: id(1) };
    });
    await h.loader.load(["TANK_1", id(1), id(2)]);
    assert.equal(h.errors.length, 1); assert.equal(h.published[0][0].length, 1); assert.equal(h.completed.length, 1);
});

test("a failed full-list load finishes and cannot publish an empty success", async () => {
    const h = harness(async () => { throw new Error("offline"); }); await h.loader.load();
    assert.equal(h.errors.length, 1); assert.equal(h.completed.length, 1); assert.equal(h.published.length, 0);
});

test("late untagged response cannot change a newer selection", async () => {
    let resolveOld;
    const h = harness(async (url) => {
        if (url.endsWith("untagged")) return new Promise((resolve) => { resolveOld = resolve; });
        if (url === "/api/archives") return [{ arcid: id(1) }];
        return { arcid: id(2) };
    });
    const old = h.loader.load(); await tick();
    await h.loader.load([id(2)]); resolveOld([id(1)]); await old;
    assert.equal(h.published.length, 1); assert.deepEqual([...h.published[0][1]], [id(2)]);
});
