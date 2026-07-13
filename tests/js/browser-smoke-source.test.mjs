import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("quick-filter smoke observes and requires the DataTables search request", async () => {
    const script = await source("tools/browser/quickfilter-smoke.mjs");

    assert.match(script, /\/\\\/search\$\//);
    assert.doesNotMatch(script, /\\\/api\\\/search/);
    assert.match(script, /dataTablesRequests\.length = 0/);
    assert.match(script, /dataTablesRequestsCount === 0/);
    assert.match(script, /NEW_ONLY did not trigger a DataTables \/search request/);
});
