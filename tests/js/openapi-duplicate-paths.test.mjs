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

test("fork OpenAPI documents conditional search and duplicate review contracts", () => {
    const searchStart = openapi.indexOf("        - name: groupby_tanks");
    const searchEnd = openapi.indexOf("      responses:", searchStart);
    const groupByTanks = openapi.slice(searchStart, searchEnd);
    assert.match(groupByTanks, /Defaults to true for regular\s+clients/);
    assert.match(groupByTanks, /Tachiyomi-family clients[\s\S]*overrides the default to false/);
    assert.doesNotMatch(groupByTanks, /default: true/);

    const pairsStart = openapi.indexOf("  /duplicates/pairs:");
    const pairsEnd = openapi.indexOf("  /duplicates/stats:", pairsStart);
    const duplicatePairs = openapi.slice(pairsStart, pairsEnd);
    assert.match(duplicatePairs, /name: status[\s\S]*default: new/);
    assert.match(duplicatePairs, /status=all bypasses\s+the filter/);

    const statusStart = openapi.indexOf("  /duplicates/cover/status:");
    const statusEnd = openapi.indexOf("  /stamps/{id}:", statusStart);
    const coverStatus = openapi.slice(statusStart, statusEnd);
    assert.match(coverStatus, /enum: \[new, same_cover, variant, not_duplicate, needs_review, resolved\]/);
    assert.match(coverStatus, /event_logged:/);
    assert.match(coverStatus, /warning:/);
    assert.match(coverStatus, /event_id:/);
    const badRequestStart = coverStatus.indexOf("        '400':");
    const badRequest = coverStatus.slice(badRequestStart);
    assert.notEqual(badRequestStart, -1);
    assert.match(badRequest, /required: \[error\]/);
    assert.match(badRequest, /error:\s+type: string/);
    assert.doesNotMatch(badRequest, /OperationResponse/);
});
