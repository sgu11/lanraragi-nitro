import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const openapi = await readFile(new URL("../../tools/openapi.yaml", import.meta.url), "utf8");

test("duplicate OpenAPI paths are relative to the /api server base", () => {
    const expected = [
        "/duplicates/pairs",
        "/duplicates/stats",
        "/duplicates/refresh",
        "/duplicates/cover/stats",
        "/duplicates/cover/pairs",
        "/duplicates/cover/review-events",
        "/duplicates/cover/refresh",
        "/duplicates/cover/rebuild",
        "/duplicates/cover/status",
    ];

    for (const path of expected) {
        assert.match(openapi, new RegExp(`^  ${path.replaceAll("/", "\\/")}:$`, "m"));
    }
    assert.doesNotMatch(openapi, /^  \/api\/duplicates\//m);
    assert.match(openapi, /Cover Hamming distance ceiling \(default 22\)\./);
});
