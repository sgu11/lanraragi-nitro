import assert from "node:assert/strict";
import test from "node:test";
import { createSpreadFeedback } from "../../public/js/mod/reader-spread.js";

const state = { doublePageMode: true, maxPage: 20, widePages: new Set() };
const windowAt = (start) => ({ start, end: start + 1 });
function fixture(persistOverride) {
    const writes = [], commits = [], errors = [];
    const feedback = createSpreadFeedback({
        persist: persistOverride || (async (...args) => writes.push(args)),
        commit: (...args) => commits.push(args), onError: (error) => errors.push(error),
    });
    const begin = (kind, from, direction = 1, extra = {}) => feedback.begin({
        archiveId: "archive-a", kind, direction, source: windowAt(from),
        requested: windowAt(from + direction), enabled: true, ...extra,
    });
    return { feedback, begin, writes, commits, errors };
}

test("one slide followed by a committed same-direction spread records one correction", async () => {
    for (const direction of [1, -1]) {
        const f = fixture();
        const source = direction === 1 ? 1 : 7;
        const target = source + direction;
        await f.begin("slide", source, direction)(windowAt(target), state);
        assert.equal(f.writes.length, 0);
        await f.begin("normal", target, direction)(windowAt(target + 2 * direction), state);
        assert.deepEqual(f.writes, [["archive-a", 4]]);
        assert.deepEqual(f.commits, [["archive-a", 4]]);
        await f.begin("normal", target + 2 * direction, direction)(windowAt(target + 4 * direction), state);
        assert.equal(f.writes.length, 1);
    }
});

test("reverse, second slide, jump, archive change, wide page and disabled mode cancel feedback", async () => {
    for (const scenario of ["reverse", "slide", "jump", "archive", "wide", "disabled", "failed"]) {
        const f = fixture();
        await f.begin("slide", 3)(windowAt(4), state);
        const kind = ["slide", "jump"].includes(scenario) ? scenario : "normal";
        const complete = f.begin(kind, 4, scenario === "reverse" ? -1 : 1, {
            archiveId: scenario === "archive" ? "archive-b" : "archive-a", enabled: scenario !== "disabled",
        });
        if (scenario !== "failed") {
            await complete(windowAt(scenario === "slide" ? 5 : scenario === "reverse" ? 2 : 6),
                { ...state, widePages: new Set(scenario === "wide" ? [6] : []) });
        }
        await f.begin("normal", 6)(windowAt(8), state);
        assert.equal(f.writes.length, 0, scenario);
    }
});

test("wide restart ambiguity and solitary pages do not become global anchor labels", async () => {
    const f = fixture();
    await f.begin("slide", 3)(windowAt(4), { ...state, widePages: new Set([1]) });
    await f.begin("normal", 4)(windowAt(6), { ...state, widePages: new Set([1]) });
    assert.equal(f.writes.length, 0);
    await f.begin("slide", 0, 1, { source: { start: 0, end: 0 } })(windowAt(1), state);
    await f.begin("normal", 1)(windowAt(3), state);
    assert.equal(f.writes.length, 0);
});

test("obsolete navigation and late persistence responses cannot change current layout", async () => {
    let resolve;
    const f = fixture(() => new Promise((done) => { resolve = done; }));
    const stale = f.begin("slide", 1);
    f.begin("jump", 1);
    await stale(windowAt(2), state);
    await f.begin("normal", 2)(windowAt(4), state);
    assert.equal(resolve, undefined);
    await f.begin("slide", 1)(windowAt(2), state);
    const saving = f.begin("normal", 2)(windowAt(4), state);
    f.feedback.cancel();
    resolve();
    await saving;
    assert.equal(f.commits.length, 0);
});

test("failed persistence is not re-armed by subsequent navigation", async () => {
    let attempts = 0;
    const f = fixture(async () => { attempts++; throw new Error("network"); });
    await f.begin("slide", 1)(windowAt(2), state);
    await f.begin("normal", 2)(windowAt(4), state);
    await f.begin("normal", 4)(windowAt(6), state);
    assert.equal(attempts, 1);
    assert.equal(f.commits.length, 0);
    assert.equal(f.errors.length, 1);
});
