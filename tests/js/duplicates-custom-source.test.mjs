import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("custom duplicate finder exposes only cover-image comparison", async () => {
    const script = await source("public/js/duplicates_custom.js");
    const template = await source("templates/duplicates_custom.html.tt2");

    assert.match(template, /id="run-find-cover"/);
    assert.doesNotMatch(template, /id="run-find"/);
    assert.doesNotMatch(template, /id="run-backfill"/);
    assert.doesNotMatch(template, /id="relation-select"/);

    assert.match(script, /find_cover_duplicates/);
    assert.match(script, /backfill_coverhashes/);
    assert.doesNotMatch(script, /find_relation_duplicates/);
    assert.doesNotMatch(script, /backfill_dedup_signals/);
    assert.doesNotMatch(script, /relation=/);
    assert.doesNotMatch(script, /title_score/);
});
