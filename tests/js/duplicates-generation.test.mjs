import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const source = await readFile(new URL("../../public/js/duplicates_custom.js", import.meta.url), "utf8");
function harness(fetch) {
    const element = new Proxy({}, { get: () => () => element });
    const context = vm.createContext({
        LRR: { ApiURL: class { constructor(path) { this.path = path; } toString() { return this.path; } }, showPopUp() {} },
        I18N: {},
        window: { localStorage: { getItem: () => null } },
        $: () => element,
        fetch,
        setTimeout,
        URLSearchParams,
    });
    vm.runInContext(source.replace(/^import .*;$/gm, "") + "\nglobalThis.duplicates = Duplicates;", context);
    return context.duplicates;
}

test("review and dismissal send the generation of the displayed pair", async () => {
    const requests = [];
    const d = harness(async (url, init) => {
        requests.push({ url: String(url), ...JSON.parse(init.body) });
        return { ok: true, status: 200, text: async () => "{}" };
    });
    const pair = { id_a: "a", id_b: "b", generation: "displayed-generation", a: {}, b: {} };
    await d.updateStatus("a|b", "same_cover", d.reviewLogPayload(pair, "keyboard"));
    await d.dismissPair("a|b", pair.generation);
    assert.equal(requests[0].generation, "displayed-generation");
    assert.equal(requests[0].context.input_method, "keyboard");
    assert.equal(requests[1].generation, "displayed-generation");
});

test("stale review reloads the queue instead of advancing an obsolete pair", async () => {
    const d = harness(async () => ({ ok: false, status: 409, text: async () => JSON.stringify({ error: "Pair changed" }) }));
    let reloads = 0;
    let advances = 0;
    d.loadPairs = () => { reloads++; return Promise.resolve(); };
    d.advanceAfterReviewAction = () => { advances++; };
    const pair = { id_a: "a", id_b: "b", generation: "stale" };
    const result = await d.performReviewAction({
        pair,
        action: () => d.updateStatus("a|b", "same_cover", { generation: pair.generation }),
        errorTitle: "Review failed",
    });
    assert.equal(result, false);
    assert.equal(reloads, 1);
    assert.equal(advances, 0);
    assert.equal(d._reviewActionInFlight, false);
});

test("ordinary failed review keeps the queue for retry", async () => {
    const d = harness(async () => ({ ok: false, status: 503, text: async () => "{}" }));
    let reloads = 0;
    d.loadPairs = () => { reloads++; };
    await d.performReviewAction({ pair: {}, action: () => d.updateStatus("a|b", "variant"), errorTitle: "Review failed" });
    assert.equal(reloads, 0);
    assert.equal(d._reviewActionInFlight, false);
});

test("archive deletion carries the displayed pair generation and fails closed without it", async () => {
    const requests = [];
    const d = harness(async (url, init) => {
        requests.push({ url: new URL(String(url), "http://localhost"), method: init.method });
        return { ok: true, status: 200, text: async () => "{}" };
    });
    const pair = { id_a: "a", id_b: "b", generation: "displayed-pair" };
    await d.deleteArchive("b", pair);
    assert.equal(requests[0].method, "DELETE");
    assert.equal(requests[0].url.pathname, "/api/archives/b");
    assert.equal(requests[0].url.searchParams.get("cover_pair"), "a|b");
    assert.equal(requests[0].url.searchParams.get("cover_generation"), "displayed-pair");
    await assert.rejects(d.deleteArchive("b", { ...pair, generation: undefined }), { status: 409 });
    assert.equal(requests.length, 1);
});
