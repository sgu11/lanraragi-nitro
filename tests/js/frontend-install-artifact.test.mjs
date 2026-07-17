import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

const root = new URL("../../", import.meta.url);
const rootPath = fileURLToPath(root);
const source = (path) => readFile(new URL(path, root), "utf8");

test("clean frontend install builds the Swiper artifact consumed through the import map", async (t) => {
    const [installer, importmap, indexModule, packageJson] = await Promise.all([
        source("tools/install.pl"),
        source("templates/common/importmap.html.tt2"),
        source("public/js/mod/index.js"),
        source("package.json"),
    ]);
    const entryMatch = installer.match(/my @vendor_bundle = \(\s*"([^"]+swiper-bundle\.mjs)"/);
    assert.ok(entryMatch, "tools/install.pl must declare the Swiper ESM bundle input");

    const entry = join(rootPath, "node_modules", entryMatch[1].replace(/^\//, ""));
    const expectedArtifact = basename(entry).replace(/\.mjs$/, ".js");
    assert.match(importmap, new RegExp(`/vendor/${expectedArtifact.replace(".", "\\.")}\\?\\$asset_version`));
    assert.match(indexModule, /import\("swiper"\)/);
    assert.doesNotMatch(indexModule, /window\.Swiper|swiper-bundle\.min\.js/);
    const vendorInputs = installer.match(/my @vendor_js = \([\s\S]*?my @vendor_bundle = \([\s\S]*?\);/)?.[0] || "";
    assert.doesNotMatch(`${vendorInputs}\n${importmap}\n${packageJson}`, /@preact\/signals|signals-core\.module\.js|signals\.module\.js/);
    assert.match(installer, /unlink map \{ getcwd \. "\/public\/js\/vendor\/" \. \$_ \}/);

    const outdir = await mkdtemp(join(tmpdir(), "lrr-front-artifact-"));
    t.after(() => rm(outdir, { recursive: true, force: true }));
    const esbuildCli = join(rootPath, "node_modules", "esbuild", "bin", "esbuild");
    const build = spawnSync(esbuildCli, ["--bundle", "--format=esm", "--minify",
        "--external:react", `--outdir=${outdir}`, entry], {
        cwd: new URL(root),
        encoding: "utf8",
    });
    assert.equal(build.status, 0, `clean npm ci is required before this test:\n${build.stdout}${build.stderr}`);

    const artifact = join(outdir, expectedArtifact);
    const swiperModule = await import(pathToFileURL(artifact));
    assert.equal(typeof swiperModule.default, "function", `${expectedArtifact} must provide Swiper as its default export`);
});
