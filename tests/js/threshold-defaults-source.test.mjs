import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const read = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("cover threshold default is 22 in UI, CoverIndex constant, and API fallback", async () => {
    const ui = await read("public/js/duplicates_custom.js");
    const coverIndex = await read("lib/LANraragi/Model/Dedup/CoverIndex.pm");
    const api = await read("lib/LANraragi/Controller/Api/Coverduplicates.pm");

    assert.match(ui, /DUPES_THRESHOLD_DEFAULT\s*=\s*22/);
    assert.match(coverIndex, /DEFAULT_COVER_MAX_HAMMING\s*=>\s*22/);
    assert.match(api, /DEFAULT_COVER_MAX_HAMMING\(\)/);
    assert.doesNotMatch(api, /\/\/\s*25\)\s*\+\s*0/);
    assert.doesNotMatch(coverIndex, /cover_max_hamming\s*\/\/\s*12/);
});
