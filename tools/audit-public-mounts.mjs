#!/usr/bin/env node
/**
 * Predeploy audit: ensure fork-required public JS/CSS (and openapi) paths appear
 * in a mounts inventory. The live deploy compose is host-only; pass a fixture
 * list so CI/laptop can run offline.
 *
 * Usage:
 *   node tools/audit-public-mounts.mjs --mounts-file path/to/mounts.txt
 *   node tools/audit-public-mounts.mjs --mounts-file fixtures/complete.txt
 *
 * Mounts file format: one host-relative path per line (comments # ok).
 * Paths may be compose-style "host:container" — the host side is used.
 *
 * Exit 0 if every required path is covered; non-zero otherwise.
 */
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

/** Fork files that require individual bind mounts (see docs/DEPLOYMENT.md). */
export const FORK_PUBLIC_MOUNT_PATHS = Object.freeze([
    "tools/openapi.yaml",
    "public/js/mod/reader-spread.js",
    "public/js/mod/progress-migration.js",
    "public/js/mod/reader-chrome.js",
    "public/js/mod/reader-crop.js",
    "public/js/mod/reader-nav-keys.js",
    "public/js/mod/archive-data-cache.js",
    "public/js/mod/perf.js",
    "public/js/mod/index_contextmenu.js",
    "public/js/mod/index_grid_selection.js",
    "public/css/reader-chrome.css",
    "public/js/duplicates_custom.js",
    "public/css/duplicates_custom.css",
]);

export function parseMountsInventory(text) {
    const paths = new Set();
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.replace(/#.*$/, "").trim();
        if (!line) continue;
        // compose: "./LANraragi/public/js/foo.js:/home/.../foo.js:ro"
        const hostSide = line.split(":")[0].trim();
        const normalized = hostSide
            .replace(/^\.\//, "")
            .replace(/^LANraragi\//, "")
            .replace(/\\/g, "/");
        // Keep trailing path from public/ or tools/
        const pub = normalized.match(/(public\/.+|tools\/openapi\.yaml)$/);
        if (pub) {
            paths.add(pub[1]);
        } else {
            paths.add(normalized);
        }
    }
    return paths;
}

export function auditMounts(mountedPaths, required = FORK_PUBLIC_MOUNT_PATHS) {
    const missing = [];
    for (const req of required) {
        if (!mountedPaths.has(req)) {
            missing.push(req);
        }
    }
    return { ok: missing.length === 0, missing, required: [...required] };
}

function main(argv = process.argv.slice(2)) {
    let mountsFile = null;
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === "--mounts-file" && argv[i + 1]) {
            mountsFile = argv[++i];
        }
    }
    if (!mountsFile) {
        console.error("Usage: node tools/audit-public-mounts.mjs --mounts-file <inventory.txt>");
        process.exit(2);
    }
    const abs = resolve(process.cwd(), mountsFile);
    if (!existsSync(abs)) {
        console.error(`Mounts file not found: ${abs}`);
        process.exit(2);
    }
    const text = readFileSync(abs, "utf8");
    const mounted = parseMountsInventory(text);
    const result = auditMounts(mounted);

    // Also warn if required files missing from repo (structural).
    const absentOnDisk = FORK_PUBLIC_MOUNT_PATHS.filter((p) => !existsSync(join(REPO_ROOT, p)));

    if (result.ok && absentOnDisk.length === 0) {
        console.log(JSON.stringify({ ok: true, checked: result.required.length, mountsFile: abs }, null, 2));
        process.exit(0);
    }

    console.error(JSON.stringify({
        ok: false,
        missing_mounts: result.missing,
        missing_on_disk: absentOnDisk,
        mountsFile: abs,
    }, null, 2));
    process.exit(1);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) {
    main();
}
