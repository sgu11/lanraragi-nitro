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

test("custom duplicate finder renders a focused review queue", async () => {
    const script = await source("public/js/duplicates_custom.js");
    const template = await source("templates/duplicates_custom.html.tt2");
    const styles = await source("public/css/duplicates_custom.css");

    assert.match(template, /id="dupes-review-shell"/);
    assert.match(template, /id="dupes-active-stage"/);
    assert.match(template, /id="dupes-queue-rail"/);
    assert.match(template, /id="dupes-queue-list"/);

    assert.match(styles, /#dupes-review-shell/);
    assert.match(styles, /\.dupe-focus-card/);
    assert.match(styles, /\.dupe-queue-item/);

    assert.match(script, /Duplicates\.renderActivePair\s*=/);
    assert.match(script, /Duplicates\.renderQueueRail\s*=/);
    assert.match(script, /Duplicates\.advanceAfterReviewAction\s*=/);
    assert.match(script, /Duplicates\.loadMorePairs\s*=/);
    assert.match(script, /Duplicates\.performReviewAction\s*=/);
});

test("custom duplicate review actions do not reload the whole deck", async () => {
    const script = await source("public/js/duplicates_custom.js");

    assert.match(script, /data-action="keep-side"/);
    assert.match(script, /data-action="mark-status"/);
    assert.match(script, /data-status="needs_review"/);
    assert.match(script, /function\s*\(\)\s*\{[\s\S]*\.dupe-action[\s\S]*Duplicates\.performReviewAction/);

    const actionHandlerStart = script.indexOf("$(\"#dupes-active-stage\").on(\"click\", \".dupe-action\"");
    assert.notEqual(actionHandlerStart, -1);
    const nextHandlerStart = script.indexOf("$(document).on(\"keydown\"", actionHandlerStart);
    const actionHandler = script.slice(actionHandlerStart, nextHandlerStart);
    assert.doesNotMatch(actionHandler, /Duplicates\.loadPairs\(\)/);
});

test("custom duplicate finder renders pair-relative comparison chips", async () => {
    const script = await source("public/js/duplicates_custom.js");
    const styles = await source("public/css/duplicates_custom.css");
    const template = await source("templates/duplicates_custom.html.tt2");

    assert.match(script, /compareArchiveSignals/);
    assert.match(script, /renderResolutionChips/);
    assert.match(script, /cover_pixels/);
    assert.match(script, /cover_width/);
    assert.match(script, /isKoreanLanguage/);
    assert.match(script, /dupe-resolution-chip/);
    assert.match(script, /is-highlighted/);

    assert.match(styles, /\.dupe-resolution-chips/);
    assert.match(styles, /\.dupe-resolution-chip/);
    assert.match(styles, /\.dupe-resolution-chip\.is-highlighted/);

    assert.match(template, /duplicates_custom\.css"\) %]\?\[% version %]-comparison-chips/);
    assert.match(template, /duplicates_custom\.js"\) %]\?\[% version %]-comparison-chips/);
});

test("custom duplicate fork-only labels do not call Maketext", async () => {
    const template = await source("templates/duplicates_custom.html.tt2");
    const forkOnlyLabels = [
        "Refresh deck",
        "Find cover matches",
        "Cover Hamming threshold:",
        "Status:",
        "Keyboard: n/p=next/previous",
    ];

    for (const label of forkOnlyLabels) {
        assert.doesNotMatch(template, new RegExp(`c\\.lh\\(\"${label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
    }
});
