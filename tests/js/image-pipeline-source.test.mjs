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

test("reader Delete key confirms archive deletion before returning to library", async () => {
    const js = await source("public/js/reader.js");
    const shortcutStart = js.indexOf("function handleShortcuts(e)");
    const shortcutEnd = js.indexOf("function spaceScrollProcessInput(e)");
    const shortcuts = js.slice(shortcutStart, shortcutEnd);
    const helperStart = js.indexOf("function confirmDeleteArchive()");
    const helperEnd = js.indexOf("\nexport function ", helperStart + 1);
    const helper = js.slice(helperStart, helperEnd === -1 ? js.length : helperEnd);

    assert.notEqual(shortcutStart, -1);
    assert.notEqual(shortcutEnd, -1);
    assert.match(shortcuts, /case 46:\s*\/\/ delete\s+confirmDeleteArchive\(\);\s+break;/);
    assert.match(js, /\$\(document\)\.on\("click\.delete-archive", "#delete-archive", confirmDeleteArchive\);/);

    assert.notEqual(helperStart, -1);
    assert.match(helper, /LRR\.showPopUp\(\{/);
    assert.match(helper, /text: isTank \? I18N\.ConfirmTankoubonDeletion : I18N\.ConfirmArchiveDeletion,/);
    assert.match(helper, /showCancelButton: true,/);
    assert.match(helper, /focusConfirm: true,/);
    assert.match(helper, /allowEnterKey: true,/);
    assert.match(helper, /confirmButtonText: I18N\.ConfirmYes,/);
    assert.match(helper, /if \(result\.isConfirmed\) \{\s*deleteCurrentArchive\(\);\s*\}/);
    assert.match(js, /function returnToLibrary\(\) \{\s*document\.location\.href = "\.\/";\s*\}/);
    assert.match(js, /Server\.deleteArchive\(id, returnToLibrary\);/);
});
