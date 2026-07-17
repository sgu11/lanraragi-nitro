import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
    getReaderIntentStartIndex,
    metadataResponseMeansMissing,
    shouldMigrateProgressValue,
    shouldRunProgressMigration,
} from "../../public/js/mod/progress-migration.js";

const source = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");

test("progress migration runs only when server-side progress is available for this user", () => {
    assert.equal(shouldRunProgressMigration(true, false, true), false);
    assert.equal(shouldRunProgressMigration(false, true, false), false);
    assert.equal(shouldRunProgressMigration(false, true, true), true);
    assert.equal(shouldRunProgressMigration(false, false, false), true);
});

test("missing archive metadata responses are treated as stale local progress", () => {
    assert.equal(metadataResponseMeansMissing({ status: 404 }, null), true);
    assert.equal(
        metadataResponseMeansMissing(
            { status: 400 },
            { success: 0, error: "This ID doesn't exist on the server." },
        ),
        true,
    );
    assert.equal(
        metadataResponseMeansMissing(
            { status: 400 },
            { success: 0, error: "This ID doesn&#39;t exist on the server." },
        ),
        true,
    );
    assert.equal(
        metadataResponseMeansMissing(
            { status: 400 },
            { success: 0, error: "Server-side Progress Tracking is disabled on this instance." },
        ),
        false,
    );
});

test("progress migration compares page numbers numerically", () => {
    assert.equal(shouldMigrateProgressValue("10", 2), true);
    assert.equal(shouldMigrateProgressValue("2", 10), false);
    assert.equal(shouldMigrateProgressValue(null, 0), false);
    assert.equal(shouldMigrateProgressValue("not-a-number", 0), false);
    assert.equal(shouldMigrateProgressValue("10bad", 2), false);
});

test("reader intent converts persisted progress to the exact opening page", () => {
    assert.equal(getReaderIntentStartIndex(0, 20), 0);
    assert.equal(getReaderIntentStartIndex(1, 20), 0);
    assert.equal(getReaderIntentStartIndex(5, 20), 4);
    assert.equal(getReaderIntentStartIndex("19", "20"), 18);
    assert.equal(getReaderIntentStartIndex(20, 20), 0);
    assert.equal(getReaderIntentStartIndex(21, 20), 0);
    assert.equal(getReaderIntentStartIndex("not-a-page", 20), 0);
});

test("index progress migration does not require a new common.js getter", async () => {
    const index = await source("public/js/mod/index.js");

    assert.doesNotMatch(index, /LRR\.getProgressTracking\(\)/);
    assert.match(index, /let progressTracking = \{\s*isProgressLocal: true,\s*isProgressAuthenticated: true,\s*\};/);
    assert.match(index, /progressTracking = \{\s*isProgressLocal: !data\.server_tracks_progress,\s*isProgressAuthenticated: data\.authenticated_progress,\s*\};/);
    assert.match(index, /LRR\.setProgressTracking\(\s*progressTracking\.isProgressLocal,\s*progressTracking\.isProgressAuthenticated,\s*\);/);
    assert.match(index, /const \{ isProgressLocal, isProgressAuthenticated \} = progressTracking;/);
});
