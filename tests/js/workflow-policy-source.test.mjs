import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");

function workflow(name) {
    return readFileSync(join(root, ".github/workflows", name), "utf8");
}

test("branch pushes use the fast gate while guarded jobs remain conditional", () => {
    const source = workflow("push-continuous-integration.yml");

    assert.match(source, /push:\n\s+branches:\n\s+- dev/);
    assert.match(source, /name: Fast fork push gate/);
    assert.match(source, /needs\.classify\.outputs\.full_gate == 'true'/);
    assert.match(source, /needs\.classify\.outputs\.perl == 'true'/);
    assert.match(source, /needs\.classify\.outputs\.long_browser == 'true'/);
    assert.match(source, /git merge-base "\$CURRENT_SHA" "origin\/\$DEFAULT_BRANCH"/);
    assert.match(source, /--changes-file \/tmp\/lrr-change-inventory\/lrr-changes\.txt/);
    assert.match(source, /github\.event_name == 'workflow_dispatch' && inputs\.run_windows_integration/);
});

test("nightly multi-platform, Windows, and Homebrew jobs are manual", () => {
    const delivery = workflow("push-continous-delivery.yml");
    const brew = workflow("push-brewtest.yml");

    assert.match(delivery, /^"on":\n\s+workflow_dispatch:/);
    assert.doesNotMatch(delivery, /^\s+push:/m);
    assert.match(delivery, /if: \$\{\{ inputs\.publish_multiarch_docker \}\}/);
    assert.match(delivery, /if: \$\{\{ inputs\.build_windows_msi \}\}/);
    assert.match(brew, /^"on": workflow_dispatch/);
    assert.doesNotMatch(brew, /^\s*push:/m);
});

test("public artifacts still have an explicit release trigger", () => {
    const source = workflow("release-delivery.yml");

    assert.match(source, /^"on":\n\s+release:\n\s+types: \[published\]/);
    assert.doesNotMatch(source, /^\s+push:/m);
});
