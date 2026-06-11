import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("index title tooltip thumbnails defer network work until hover", async () => {
    const js = await source("public/js/mod/index_datatables.js");

    assert.match(js, /data-src="\$\{thumbSrc\}"/);
    assert.match(js, /lazy-tooltip-thumbnail/);
    assert.doesNotMatch(js, /style="height:300px" src="\$\{thumbSrc\}"/);
});

test("thumbnail cards mark archive images as lazy", async () => {
    const js = await source("public/js/mod/common.js");

    assert.match(js, /loading="lazy" src="\$\{thumbSrc\}"/);
});

test("reader Blob URL preloading dedupes in-flight fetches and revokes evicted URLs", async () => {
    const js = await source("public/js/reader.js");

    assert.match(js, /MAX_PRELOADED_IMAGES/);
    assert.match(js, /preloadedPromises/);
    assert.match(js, /URL\.revokeObjectURL/);
});

test("reader disabled progress tracking suppresses persistence while preserving stamps", async () => {
    const js = await source("public/js/reader.js");
    const start = js.indexOf("function updateProgress()");
    const end = js.indexOf("function preloadImages()");
    const updateProgress = js.slice(start, end);

    assert.notEqual(start, -1);
    assert.notEqual(end, -1);
    assert.match(updateProgress, /if \(!ignoreProgress\) \{[\s\S]*Server\.updateServerSideProgress\(id, page\);[\s\S]*localStorage\.setItem\(`\$\{id\}-reader`, page\);[\s\S]*\n    \}/);
    assert.match(updateProgress, /\/\/ Load stamps[\s\S]*loadStamps\(page\);/);
    assert.ok(updateProgress.indexOf("if (!ignoreProgress)") < updateProgress.indexOf("// Load stamps"));
});
