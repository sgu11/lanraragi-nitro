import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
    FORK_PUBLIC_MOUNT_PATHS,
    parseMountsInventory,
    auditMounts,
} from "../../tools/audit-public-mounts.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

test("complete mounts fixture covers every required path", () => {
    const text = readFileSync(join(root, "tools/fixtures/mounts-complete.txt"), "utf8");
    const mounted = parseMountsInventory(text);
    const result = auditMounts(mounted);
    assert.equal(result.ok, true, `missing: ${result.missing.join(", ")}`);
    assert.ok(FORK_PUBLIC_MOUNT_PATHS.includes("public/js/mod/reader-nav-keys.js"));
});

test("incomplete mounts fixture fails on missing reader-nav-keys", () => {
    const text = readFileSync(join(root, "tools/fixtures/mounts-missing-nav-keys.txt"), "utf8");
    const mounted = parseMountsInventory(text);
    const result = auditMounts(mounted);
    assert.equal(result.ok, false);
    assert.ok(result.missing.includes("public/js/mod/reader-nav-keys.js"));
});

test("CLI exits non-zero for incomplete inventory and zero for complete", () => {
    const script = join(root, "tools/audit-public-mounts.mjs");
    const fail = spawnSync(process.execPath, [script, "--mounts-file", "tools/fixtures/mounts-missing-nav-keys.txt"], {
        cwd: root,
        encoding: "utf8",
    });
    assert.notEqual(fail.status, 0, fail.stdout + fail.stderr);

    const ok = spawnSync(process.execPath, [script, "--mounts-file", "tools/fixtures/mounts-complete.txt"], {
        cwd: root,
        encoding: "utf8",
    });
    assert.equal(ok.status, 0, ok.stdout + ok.stderr);
});
