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
    assert.match(source, /testSuite:[\s\S]*?runs-on: ubuntu-latest/);
    assert.match(source, /integrationTestsDocker:[\s\S]*?runs-on: ubuntu-latest/);
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

test("artifact transfer uses supported GitHub Actions versions", () => {
    const source = workflow("push-continuous-integration.yml");
    const artifactActions = [...source.matchAll(/actions\/(?:upload|download)-artifact@v\d+/g)]
        .map((match) => match[0]);

    assert.deepEqual(artifactActions, [
        "actions/upload-artifact@v7",
        "actions/download-artifact@v4",
        "actions/upload-artifact@v7",
        "actions/upload-artifact@v7",
    ]);
});

test("guarded suite builds its Docker action context after copying tests", () => {
    const source = workflow("push-continuous-integration.yml");

    assert.match(source, /cp -R tests \.github\/action-run-tests/);
    assert.match(source, /docker build --tag lanraragi:test-suite \.github\/action-run-tests/);
    assert.match(source, /docker run --rm lanraragi:test-suite/);
    assert.doesNotMatch(source, /uses: \.\/\.github\/action-run-tests/);
});

test("guarded test entrypoint starts its required local Valkey service", () => {
    const entrypoint = readFileSync(join(root, ".github/action-run-tests/entrypoint.sh"), "utf8");

    assert.match(entrypoint, /s6-setuidgid koyomi valkey-server tools\/build\/docker\/redis\.conf/);
    assert.match(entrypoint, /until valkey-cli ping/);
    assert.match(entrypoint, /trap cleanup EXIT/);
});

test("the guarded job checks out the external integration suite from GitHub", () => {
    const source = workflow("push-continuous-integration.yml");
    const linuxJob = source.match(/integrationTestsDocker:[\s\S]*?\n  integrationTestsWindows:/)?.[0];

    assert.ok(linuxJob);

    assert.match(
        linuxJob,
        /Checkout aio-lanraragi integration tests[\s\S]*?https:\/\/github\.com\/\$\{INTEGRATION_TEST_REPOSITORY\}\.git/,
    );
    assert.match(linuxJob, /git -C aio-lanraragi fetch --depth=1 origin "\$INTEGRATION_TEST_REF"/);
    assert.match(
        linuxJob,
        /git -C aio-lanraragi apply --unidiff-zero --check[\s\\]*\.\.\/lanraragi\/tools\/fixtures\/aio-lanraragi-nitro\.patch/,
    );
    assert.match(
        linuxJob,
        /git -C aio-lanraragi apply --unidiff-zero[\s\\]*\.\.\/lanraragi\/tools\/fixtures\/aio-lanraragi-nitro\.patch/,
    );
    assert.match(linuxJob, /PLAYWRIGHT_HOST_PLATFORM_OVERRIDE: ubuntu24\.04-x64/);
    assert.doesNotMatch(
        linuxJob,
        /- name: Checkout aio-lanraragi integration tests\n[ \t]+uses: actions\/checkout/,
    );
});

test("public artifacts still have an explicit release trigger", () => {
    const source = workflow("release-delivery.yml");

    assert.match(source, /^"on":\n\s+release:\n\s+types: \[published\]/);
    assert.doesNotMatch(source, /^\s+push:/m);
});
