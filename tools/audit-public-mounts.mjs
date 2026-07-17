#!/usr/bin/env node
/**
 * Predeploy audit: ensure fork-required public JS/CSS (and openapi) paths appear
 * in a mounts inventory. The live deploy compose is host-only; pass a fixture
 * list so CI/laptop can run offline.
 *
 * Usage:
 *   node tools/audit-public-mounts.mjs --mounts-file path/to/mounts.txt
 *     [--changes-file path/to/git-name-status.txt]
 *   node tools/audit-public-mounts.mjs --mounts-file fixtures/complete.txt
 *
 * Mounts file format: one compose-style "host:container[:mode]" mount per
 * line (comments # ok). Required mounts must use the exact runtime destination.
 *
 * Exit 0 if every required path is covered; non-zero otherwise.
 */
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseChangesInventory } from "./classify-change-surface.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

/** Fork files that require individual bind mounts (see docs/DEPLOYMENT.md). */
export const FORK_PUBLIC_MOUNT_PATHS = Object.freeze([
    "tools/openapi.yaml",
    "public/js/mod/common.js",
    "public/js/duplicates.js",
    "public/js/mod/index.js",
    "public/js/mod/index_datatables.js",
    "public/js/mod/index-order.js",
    "public/js/reader.js",
    "public/js/mod/server.js",
    "public/js/mod/reader-spread.js",
    "public/js/mod/reader-progress.js",
    "public/js/mod/progress-migration.js",
    "public/js/mod/reader-chrome.js",
    "public/js/mod/reader-crop.js",
    "public/js/mod/reader-nav-keys.js",
    "public/js/mod/reader_common.js",
    "public/js/mod/archive-data-cache.js",
    "public/js/mod/perf.js",
    "public/js/mod/index_contextmenu.js",
    "public/js/mod/index_grid_selection.js",
    "public/css/lrr.css",
    "public/css/reader-chrome.css",
    "public/js/duplicates_custom.js",
    "public/css/duplicates_custom.css",
]);

export const OBSOLETE_PUBLIC_MOUNT_PATHS = Object.freeze([
    "public/js/mod/reader_archive_overlay.js",
    "public/js/mod/reader_options.js",
    "public/js/mod/reader_stamps.js",
]);

const CONTAINER_ROOT = "/home/koyomi/lanraragi";

function normalizeHostPath(hostSide) {
    const normalized = hostSide.trim()
        .replace(/^\.\//, "")
        .replace(/^LANraragi\//, "")
        .replace(/\\/g, "/");
    const repoPath = normalized.match(/(public\/.+|tools\/openapi\.yaml)$/);
    return repoPath ? repoPath[1] : normalized;
}

export function requiredDestination(path) {
    return `${CONTAINER_ROOT}/${path}`;
}

export function parseMountsInventory(text) {
    const mounts = [];
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.replace(/#.*$/, "").trim();
        if (!line) continue;
        const [hostSide, destination = ""] = line.split(":");
        mounts.push({
            source: normalizeHostPath(hostSide),
            destination: destination.trim().replace(/\\/g, "/"),
        });
    }
    return mounts;
}

/**
 * Return checkout-backed JS/CSS files that must be individually mounted for a
 * Git name-status inventory. Deleted files have no destination to require;
 * stale mounts for them are caught by the reverse on-disk audit.
 */
export function requiredMountPathsFromChanges(text) {
    const required = [];
    const seen = new Set();
    for (const change of parseChangesInventory(text)) {
        if (!/^[AMTRC]/.test(change.status)) continue;
        const path = change.path;
        if (!path || !/^public\/(?:js|css)\/.+/.test(path) || seen.has(path)) continue;
        seen.add(path);
        required.push(path);
    }
    return required;
}

export function auditMounts(mounts, required = FORK_PUBLIC_MOUNT_PATHS) {
    const bySource = new Map(mounts.map((mount) => [mount.source, mount]));
    const missing = [];
    const wrongDestinations = [];
    for (const req of required) {
        const mount = bySource.get(req);
        if (!mount) {
            missing.push(req);
        } else if (mount.destination !== requiredDestination(req)) {
            wrongDestinations.push({
                source: req,
                expected: requiredDestination(req),
                actual: mount.destination,
            });
        }
    }
    const obsolete = mounts
        .filter((mount) => OBSOLETE_PUBLIC_MOUNT_PATHS.includes(mount.source))
        .map((mount) => mount.source);
    return {
        ok: missing.length === 0 && wrongDestinations.length === 0 && obsolete.length === 0,
        missing,
        wrongDestinations,
        obsolete,
        required: [...required],
    };
}

function main(argv = process.argv.slice(2)) {
    let mountsFile = null;
    let changesFile = null;
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === "--mounts-file" && argv[i + 1]) {
            mountsFile = argv[++i];
        } else if (argv[i] === "--changes-file" && argv[i + 1]) {
            changesFile = argv[++i];
        }
    }
    if (!mountsFile) {
        console.error("Usage: node tools/audit-public-mounts.mjs --mounts-file <inventory.txt> [--changes-file <git-name-status.txt>]");
        process.exit(2);
    }
    const abs = resolve(process.cwd(), mountsFile);
    if (!existsSync(abs)) {
        console.error(`Mounts file not found: ${abs}`);
        process.exit(2);
    }
    const text = readFileSync(abs, "utf8");
    const mounts = parseMountsInventory(text);
    let required = [...FORK_PUBLIC_MOUNT_PATHS];
    if (changesFile) {
        const changesAbs = resolve(process.cwd(), changesFile);
        if (!existsSync(changesAbs)) {
            console.error(`Changes file not found: ${changesAbs}`);
            process.exit(2);
        }
        required = [...new Set([
            ...required,
            ...requiredMountPathsFromChanges(readFileSync(changesAbs, "utf8")),
        ])];
    }
    const result = auditMounts(mounts, required);

    // Reverse direction: every repo-scoped source named by the inventory must
    // still exist. This catches stale mounts after upstream deletes/renames.
    const absentOnDisk = [...new Set([
        ...mounts.map((mount) => mount.source),
        ...required,
    ])]
        .filter((path) => /^(public\/|tools\/openapi\.yaml$)/.test(path))
        .filter((path) => !existsSync(join(REPO_ROOT, path)));

    if (result.ok && absentOnDisk.length === 0) {
        console.log(JSON.stringify({ ok: true, checked: result.required.length, mountsFile: abs }, null, 2));
        process.exit(0);
    }

    console.error(JSON.stringify({
        ok: false,
        missing_mounts: result.missing,
        wrong_destinations: result.wrongDestinations,
        obsolete_mounts: result.obsolete,
        missing_on_disk: absentOnDisk,
        mountsFile: abs,
    }, null, 2));
    process.exit(1);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) {
    main();
}
