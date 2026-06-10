import assert from "node:assert/strict";
import test from "node:test";

import {
    metadataResponseMeansMissing,
    shouldMigrateProgressValue,
    shouldRunProgressMigration,
} from "../../public/js/mod/progress-migration.js";

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
});
