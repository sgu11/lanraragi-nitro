import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
    classifyChangeSurface,
    parseChangesInventory,
} from "../../tools/classify-change-surface.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const script = join(root, "tools/classify-change-surface.mjs");

test("parses modified, added, deleted, and renamed name-status rows", () => {
    const changes = parseChangesInventory([
        "M\tlib/LANraragi.pm",
        "A\tpublic/js/new.js",
        "D\tpublic/css/old.css",
        "R100\tpublic/js/old.js\tpublic/js/new-name.js",
        "",
    ].join("\n"));

    assert.deepEqual(changes, [
        { status: "M", path: "lib/LANraragi.pm" },
        { status: "A", path: "public/js/new.js" },
        { status: "D", path: "public/css/old.css" },
        { status: "R100", path: "public/js/new-name.js", oldPath: "public/js/old.js" },
    ]);
});

test("a modified existing frontend file stays on the fast Tier 1 lane", () => {
    assert.deepEqual(classifyChangeSurface(parseChangesInventory("M\tpublic/js/reader.js\n")), {
        tier: 1,
        lane: "fast",
        full_gate: false,
        structural_audit: false,
        mount_audit: true,
        long_browser: false,
        frontend: true,
        perl: false,
        openapi: false,
        reasons: [],
    });
});

test("new, deleted, and renamed public assets require Tier 2 mount review", () => {
    const added = classifyChangeSurface("A\tpublic/js/new-helper.js\n");
    assert.equal(added.tier, 2);
    assert.equal(added.lane, "guarded");
    assert.equal(added.full_gate, false);
    assert.equal(added.structural_audit, false);
    assert.equal(added.mount_audit, true);
    assert.equal(added.long_browser, false);

    const deleted = classifyChangeSurface("D\tpublic/css/old-theme.css\n");
    assert.equal(deleted.tier, 2);
    assert.equal(deleted.mount_audit, true);
    assert.equal(deleted.structural_audit, false);

    const renamed = classifyChangeSurface("R100\tpublic/js/old-helper.js\tpublic/js/new-helper.js\n");
    assert.equal(renamed.tier, 2);
    assert.equal(renamed.mount_audit, true);
    assert.equal(renamed.structural_audit, true);
    assert.equal(renamed.full_gate, true);
    assert.equal(renamed.long_browser, true);
});

test("dependency and runtime inputs escalate to Tier 3", () => {
    for (const path of [
        "package.json",
        "package-lock.json",
        "tools/cpanfile",
        "tools/install.pl",
        "tools/build/docker/Dockerfile",
        "tools/build/docker/s6/s6-rc.d/lanraragi/run",
        "tools/build/all/perl-Crypt-DES-fedora-c99.patch",
        ".dockerignore",
        "lrr.conf",
        "script/lanraragi",
        "script/launcher.pl",
        "script/backup",
        "public/app.webappmanifest",
        "public/img/favicon.png",
        "public/js/vendor/swiper.min.js",
        "public/css/webfonts/lrr.woff2",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.tier, 3, path);
        assert.equal(result.lane, "guarded", path);
        assert.equal(result.full_gate, true, path);
    }

    const deletedVendor = classifyChangeSurface("D\tpublic/css/vendor/legacy.css\n");
    assert.equal(deletedVendor.tier, 3);
    assert.equal(deletedVendor.full_gate, true);
});

test("non-runtime tooling scripts stay proportional", () => {
    for (const path of [
        "tools/maintenance-helper.sh",
        ".dockerignore.bak",
        "lrr.conf.local",
        "docs/script/example.pl",
        "nested/lrr.conf",
        "tools/build/allied/helper.patch",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.tier, 1, path);
        assert.equal(result.lane, "fast", path);
        assert.equal(result.full_gate, false, path);
    }
});

test("Perl test and test-harness changes select Perl validation", () => {
    for (const path of [
        "tests/LANraragi/Model/Archive.t",
        ".github/action-run-tests/action.yml",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.perl, true, path);
    }
});

test("guarded Perl owners select the full gate", () => {
    for (const path of [
        "lib/LANraragi/Model/Archive.pm",
        "lib/LANraragi/Controller/Api/Archive.pm",
        "lib/LANraragi/Controller/Login.pm",
        "lib/LANraragi/Plugin/Login/gallery_source.pm",
        "lib/LANraragi/Utils/Minion.pm",
        "lib/Worker.pm",
        "lib/Shinobu.pm",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.tier, 1, path);
        assert.equal(result.lane, "guarded", path);
        assert.equal(result.full_gate, true, path);
        assert.equal(result.perl, true, path);
    }
});

test("public-route Perl surfaces select guarded browser evidence", () => {
    for (const path of [
        "lib/LANraragi.pm",
        "lib/LANraragi/Controller/Reader.pm",
        "lib/LANraragi/Controller/Api/Archive.pm",
        "lib/LANraragi/Controller/Index.pm",
        "lib/LANraragi/Controller/Batch.pm",
        "lib/LANraragi/Controller/Config.pm",
        "lib/LANraragi/Controller/Duplicates.pm",
        "lib/LANraragi/Utils/OpenAPI.pm",
        "lib/LANraragi/Utils/Routing.pm",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.tier, 1, path);
        assert.equal(result.lane, "guarded", path);
        assert.equal(result.full_gate, true, path);
        assert.equal(result.long_browser, true, path);
        assert.equal(result.perl, true, path);
    }
});

test("validation-policy changes cannot select their own fast-only gate", () => {
    for (const path of [
        "tools/classify-change-surface.mjs",
        "tests/js/change-surface.test.mjs",
        "tests/js/workflow-policy-source.test.mjs",
        ".github/workflows/push-continuous-integration.yml",
    ]) {
        const result = classifyChangeSurface(`M\t${path}\n`);
        assert.equal(result.tier, 1, path);
        assert.equal(result.lane, "guarded", path);
        assert.equal(result.full_gate, true, path);
        assert.equal(result.long_browser, false, path);
    }
});

test("the bind-mounted Redis config remains Tier 1 unless a data-risk gate is requested", () => {
    const result = classifyChangeSurface("M\ttools/build/docker/redis.conf\n");
    assert.equal(result.tier, 1);
    assert.equal(result.lane, "fast");
    assert.equal(result.full_gate, false);
    assert.equal(result.mount_audit, false);
    assert.equal(result.structural_audit, false);

    const guarded = classifyChangeSurface("M\ttools/build/docker/redis.conf\n", { dataRisk: true });
    assert.equal(guarded.tier, 1);
    assert.equal(guarded.lane, "guarded");
    assert.equal(guarded.full_gate, true);
});

test("OpenAPI changes activate every structural and mount gate", () => {
    const result = classifyChangeSurface("M\ttools/openapi.yaml\n");
    assert.equal(result.tier, 1);
    assert.equal(result.structural_audit, true);
    assert.equal(result.mount_audit, true);
    assert.equal(result.full_gate, true);
    assert.equal(result.long_browser, true);
    assert.equal(result.openapi, true);
});

test("data-risk is an explicit full-gate override", () => {
    const result = classifyChangeSurface([], { dataRisk: true });
    assert.equal(result.tier, 1);
    assert.equal(result.lane, "guarded");
    assert.equal(result.full_gate, true);
    assert.equal(result.structural_audit, false);
    assert.equal(result.long_browser, false);
    assert.match(result.reasons.join("\n"), /data risk/i);
});

test("more than 15 conflicts warns without changing the selected gates", () => {
    const result = classifyChangeSurface([], { conflicts: 16 });
    assert.equal(result.tier, 1);
    assert.equal(result.lane, "fast");
    assert.equal(result.full_gate, false);
    assert.equal(result.structural_audit, false);
    assert.equal(result.long_browser, false);
    assert.equal(result.mount_audit, false);
    assert.match(result.reasons.join("\n"), /conflict count 16 exceeds 15/i);
});

test("CLI emits JSON and appends exact boolean GitHub outputs", () => {
    const temp = mkdtempSync(join(tmpdir(), "lrr-change-surface-"));
    try {
        const changesFile = join(temp, "changes.txt");
        const githubOutput = join(temp, "github-output.txt");
        writeFileSync(changesFile, "M\ttools/openapi.yaml\n", "utf8");
        const run = spawnSync(process.execPath, [
            script,
            "--changes-file",
            changesFile,
            "--github-output",
            githubOutput,
        ], { cwd: root, encoding: "utf8" });

        assert.equal(run.status, 0, run.stderr);
        const result = JSON.parse(run.stdout);
        assert.equal(result.full_gate, true);
        assert.equal(result.structural_audit, true);
        assert.equal(result.mount_audit, true);
        assert.equal(result.long_browser, true);
        assert.equal(result.openapi, true);

        const output = readFileSync(githubOutput, "utf8");
        assert.equal(output, [
            "tier=1",
            "lane=guarded",
            "full_gate=true",
            "structural_audit=true",
            "mount_audit=true",
            "long_browser=true",
            "frontend=false",
            "perl=false",
            "openapi=true",
            'reasons=["Structural audit required: OpenAPI changed."]',
            "",
        ].join("\n"));
    } finally {
        rmSync(temp, { recursive: true, force: true });
    }
});

test("CLI rejects malformed status lines and invalid arguments with status 2", () => {
    const temp = mkdtempSync(join(tmpdir(), "lrr-change-surface-invalid-"));
    try {
        const changesFile = join(temp, "changes.txt");
        writeFileSync(changesFile, "Q\tunknown.txt\n", "utf8");
        const badStatus = spawnSync(process.execPath, [script, "--changes-file", changesFile], {
            cwd: root,
            encoding: "utf8",
        });
        assert.equal(badStatus.status, 2);
        assert.match(badStatus.stderr, /Invalid git status/i);

        const badArgs = spawnSync(process.execPath, [script], { cwd: root, encoding: "utf8" });
        assert.equal(badArgs.status, 2);
        assert.match(badArgs.stderr, /--changes-file is required/i);
    } finally {
        rmSync(temp, { recursive: true, force: true });
    }
});

test("CLI preserves explicit guarded and evidence overrides", () => {
    const temp = mkdtempSync(join(tmpdir(), "lrr-change-surface-overrides-"));
    try {
        const changesFile = join(temp, "changes.txt");
        writeFileSync(changesFile, "M\tREADME.md\n", "utf8");
        const cases = [
            { args: ["--data-risk"], expected: { lane: "guarded", full_gate: true } },
            { args: ["--structural"], expected: { lane: "guarded", full_gate: true, long_browser: true } },
            { args: ["--evidence"], expected: { lane: "guarded", long_browser: true } },
            { args: ["--conflicts", "16"], expected: { lane: "fast", full_gate: false } },
        ];
        for (const { args, expected } of cases) {
            const run = spawnSync(process.execPath, [script, "--changes-file", changesFile, ...args], {
                cwd: root,
                encoding: "utf8",
            });
            assert.equal(run.status, 0, run.stderr);
            const result = JSON.parse(run.stdout);
            for (const [key, value] of Object.entries(expected)) assert.equal(result[key], value, args.join(" "));
            if (args.includes("--conflicts")) assert.match(result.reasons.join("\n"), /conflict count 16/i);
        }
    } finally {
        rmSync(temp, { recursive: true, force: true });
    }
});
