import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("custom duplicate finder uses cover-only API endpoints", async () => {
    const script = await source("public/js/duplicates_custom.js");
    const template = await source("templates/duplicates_custom.html.tt2");

    // Template: exposes only cover comparison controls
    assert.match(template, /id="run-find-cover"/);
    assert.doesNotMatch(template, /id="run-find"/);
    assert.doesNotMatch(template, /id="run-backfill"/);
    assert.doesNotMatch(template, /id="relation-select"/);

    // Script: uses cover-only API endpoints
    assert.match(script, /\/api\/duplicates\/cover\/stats/);
    assert.match(script, /\/api\/duplicates\/cover\/pairs/);
    assert.match(script, /\/api\/duplicates\/cover\/rebuild/);
    assert.match(script, /\/api\/duplicates\/cover\/refresh/);

    // Script: does NOT use legacy Minion queue endpoints directly
    assert.doesNotMatch(script, /\/api\/minion\/backfill_coverhashes\/queue/);
    assert.doesNotMatch(script, /\/api\/minion\/find_cover_duplicates\/queue/);

    // Script: does NOT use relation/title/source matcher APIs
    assert.doesNotMatch(script, /find_relation_duplicates/);
    assert.doesNotMatch(script, /backfill_dedup_signals/);
    assert.doesNotMatch(script, /relation=/);
    assert.doesNotMatch(script, /title_score/);
});
