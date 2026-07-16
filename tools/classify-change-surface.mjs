#!/usr/bin/env node
/**
 * Classify a git --name-status inventory into the smallest validation and
 * deployment surface that covers the changed files.
 *
 * The input is deliberately an ordinary text inventory rather than a git
 * repository.  That keeps this tool useful to local operators and to CI jobs
 * that already computed the correct comparison range.
 *
 * Usage:
 *   node tools/classify-change-surface.mjs \
 *     --changes-file /tmp/changes.txt \
 *     [--github-output "$GITHUB_OUTPUT"] \
 *     [--data-risk] [--structural] [--evidence] [--conflicts N]
 */
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PUBLIC_ASSET_RE = /^public\/(?:js|css)(?:\/|$)/i;
const OPENAPI_RE = /(?:^|\/)openapi\.(?:ya?ml|json)$/i;
const MOUNT_AUDIT_TOOL_RE = /(?:^|\/)tools\/audit-public-mounts\.mjs$/i;
const MOUNT_AUDIT_FIXTURE_RE = /(?:^|\/)tools\/fixtures\/mounts(?:[-_].*)?\.[^/]+$/i;

// A module/vendor path is an architectural seam even when the file itself is
// only modified.  The explicit .mjs/module suffix checks cover layouts that do
// not use the fork's public/js/mod directory.
const MODULE_VENDOR_SEGMENT_RE = /(?:^|\/)(?:mod|mods|module|modules|vendor|vendors)(?:\/|$)/i;
const MODULE_VENDOR_FILE_RE = /^public\/(?:js|css)\/(?:vendor|module|modules?)[^/]*\.(?:css|js|mjs|cjs|ts|tsx|jsx)$/i;
const ES_MODULE_FILE_RE = /^public\/js\/.*\.(?:mjs|module\.(?:js|ts))$/i;

const PACKAGE_INPUT_RE = /(?:^|\/)(?:package(?:-lock)?\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock)$/i;
const CPANFILE_RE = /(?:^|\/)cpanfile(?:\.snapshot)?$/i;
const INSTALL_SCRIPT_RE = /(?:^|\/)(?:install|setup)(?:[-_.][^/]*)?\.(?:pl|pm|sh|bash|zsh|ps1|bat|cmd)$/i;
const DOCKERFILE_RE = /(?:^|\/)dockerfile(?:\.[^/]*)?$/i;
const S6_RE = /(?:^|\/)s6(?:\/|$)/i;
const DOCKER_BUILD_SUPPORT_RE = /^tools\/build\/all(?:\/|$)/i;
const IMAGE_RUNTIME_INPUT_RE = /^(?:(?:\.dockerignore|lrr\.conf)$|script(?:\/|$))/i;
const RUNTIME_INPUT_RE = /(?:^|\/)(?:runtime|entrypoint|dependencies?|requirements?)(?:[./_-]|\/|$)/i;
const IMAGE_ONLY_VENDOR_ASSET_RE = /^public\/(?:js\/vendor|css\/(?:vendor|webfonts))(?:\/|$)/i;
const IMAGE_ONLY_PUBLIC_ASSET_RE = /^public\/(?!js(?:\/|$)|css(?:\/|$)|themes(?:\/|$)).+/i;
const GUARD_POLICY_SURFACE_RE = /^(?:tools\/classify-change-surface\.mjs|tests\/js\/(?:change-surface|workflow-policy-source)\.test\.mjs|\.github\/workflows\/push-continuous-integration\.yml)$/i;
const GUARDED_ROUTE_SURFACE_RE = /^(?:lib\/LANraragi\.pm$|lib\/LANraragi\/Controller\/|lib\/LANraragi\/Utils\/(?:OpenAPI|Routing)\.pm$)/i;
const GUARDED_PERL_SURFACE_RE = /^(?:lib\/(?:Worker|Shinobu)\.pm|lib\/LANraragi\/Model\/|lib\/LANraragi\/Plugin\/Login\/|lib\/LANraragi\/Utils\/(?:Database|Login|Minion|Redis)\.pm$)/i;

const FRONTEND_PACKAGE_RE = /(?:^|\/)(?:package(?:-lock)?\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock)$/i;
const ESLINT_CONFIG_RE = /(?:^|\/)(?:eslint\.config\.[^/]+|\.eslintrc(?:\.[^/]+)?)$/i;

/**
 * Normalize a path from git's name-status output for matching.  Git emits
 * slash-separated paths on all supported platforms; accepting backslashes
 * makes the pure helpers friendlier to hand-written inventories and tests.
 */
export function normalizeChangePath(value) {
    if (typeof value !== "string") return "";
    return value.trim().replace(/\\/g, "/").replace(/^\.\//, "");
}

function parseStatusLine(rawLine, lineNumber) {
    const line = rawLine.replace(/\r$/, "");
    if (!line.trim()) return null;

    const fields = line.split("\t");
    const status = fields.shift()?.trim() ?? "";
    if (!/^(?:[MADRCTUXBY]|R\d{1,3}|C\d{1,3})$/.test(status)) {
        throw new Error(`Invalid git status on line ${lineNumber}: ${status || "(missing status)"}`);
    }

    const kind = status[0];
    if (kind === "R" || kind === "C") {
        if (fields.length < 2) {
            throw new Error(`Invalid git status on line ${lineNumber}: ${status} requires old and new paths`);
        }
        const oldPath = normalizeChangePath(fields.shift());
        const newPath = normalizeChangePath(fields.join("\t"));
        if (!oldPath || !newPath) {
            throw new Error(`Invalid git status on line ${lineNumber}: ${status} has an empty path`);
        }
        return { status, path: newPath, oldPath };
    }

    const path = normalizeChangePath(fields.join("\t"));
    if (!path) {
        throw new Error(`Invalid git status on line ${lineNumber}: ${status} has an empty path`);
    }
    return { status, path };
}

/**
 * Parse `git diff --name-status [--find-renames]` output.
 *
 * Blank lines are ignored.  Malformed or unsupported status lines throw a
 * useful error so the CLI can fail with status 2 instead of silently choosing
 * an unsafe validation lane.
 */
export function parseChangesInventory(text) {
    if (typeof text !== "string") {
        throw new TypeError("Changes inventory must be a string");
    }
    const changes = [];
    text.split(/\n/).forEach((rawLine, index) => {
        const parsed = parseStatusLine(rawLine, index + 1);
        if (parsed) changes.push(parsed);
    });
    return changes;
}

function changePaths(change) {
    if (!change || typeof change !== "object") return [];
    const paths = [];
    if (Array.isArray(change.paths)) {
        paths.push(...change.paths);
    }
    if (change.oldPath !== undefined) paths.push(change.oldPath);
    if (change.newPath !== undefined) paths.push(change.newPath);
    if (change.path !== undefined) paths.push(change.path);
    return [...new Set(paths.map(normalizeChangePath).filter(Boolean))];
}

function changeKind(change) {
    if (!change || typeof change !== "object") return "";
    const status = typeof change.status === "string" ? change.status.trim() : "";
    return status[0]?.toUpperCase() ?? "";
}

function isPublicAssetPath(path) {
    return PUBLIC_ASSET_RE.test(path);
}

function isModuleVendorPath(path) {
    return MODULE_VENDOR_SEGMENT_RE.test(path)
        || MODULE_VENDOR_FILE_RE.test(path)
        || ES_MODULE_FILE_RE.test(path);
}

function isOpenApiPath(path) {
    return OPENAPI_RE.test(path);
}

function isMountAuditPath(path) {
    return MOUNT_AUDIT_TOOL_RE.test(path) || MOUNT_AUDIT_FIXTURE_RE.test(path);
}

function isTier3Path(path) {
    if (PACKAGE_INPUT_RE.test(path) || CPANFILE_RE.test(path)) return true;
    if (INSTALL_SCRIPT_RE.test(path)) return true;
    if (DOCKERFILE_RE.test(path) || S6_RE.test(path) || DOCKER_BUILD_SUPPORT_RE.test(path) || IMAGE_RUNTIME_INPUT_RE.test(path)) return true;
    if (IMAGE_ONLY_VENDOR_ASSET_RE.test(path) || IMAGE_ONLY_PUBLIC_ASSET_RE.test(path)) return true;

    // Keep common lock/runtime manifests covered even when a project moves
    // them out of the Docker context.
    if (/^(?:\.nvmrc|\.node-version|\.perl-version|runtime(?:\/|$)|dependencies(?:\/|$))/i.test(path)) return true;
    if (RUNTIME_INPUT_RE.test(path) && /^(?:tools\/|\.github\/|docker(?:\/|$))/i.test(path)) return true;
    return false;
}

function isGuardedPerlSurface(path) {
    return GUARDED_PERL_SURFACE_RE.test(path);
}

function isGuardedRouteSurface(path) {
    return GUARDED_ROUTE_SURFACE_RE.test(path);
}

function isFrontendPath(path) {
    return isPublicAssetPath(path)
        || /^(?:templates)(?:\/|$)/i.test(path)
        || FRONTEND_PACKAGE_RE.test(path)
        || ESLINT_CONFIG_RE.test(path);
}

function isPerlPath(path) {
    return /^(?:lib|script)(?:\/|$)/i.test(path) && (/^lib(?:\/|$)/i.test(path) ? /\.pm$/i.test(path) : true)
        || /^tests\/.*\.t$/i.test(path)
        || /^\.github\/action-run-tests(?:\/|$)/i.test(path)
        || /^(?:tools\/.*\.pl|tools\/cpanfile(?:\.snapshot)?|cpanfile(?:\.snapshot)?)$/i.test(path)
        || INSTALL_SCRIPT_RE.test(path)
        || RUNTIME_INPUT_RE.test(path) && /^(?:tools\/|runtime(?:\/|$)|docker(?:\/|$)|dependencies(?:\/|$)|\.github\/)/i.test(path)
        || /^(?:tools\/build\/docker)(?:\/|$)/i.test(path) && /(?:perl|cpan|install)/i.test(path);
}

function normalizeOptions(options = {}) {
    if (!options || typeof options !== "object") return {};
    const conflicts = options.conflicts === undefined || options.conflicts === null
        ? null
        : Number(options.conflicts);
    if (conflicts !== null && (!Number.isInteger(conflicts) || conflicts < 0)) {
        throw new Error(`Invalid conflict count: ${options.conflicts}`);
    }
    return {
        dataRisk: Boolean(options.dataRisk ?? options["data-risk"]),
        structural: Boolean(options.structural),
        evidence: Boolean(options.evidence),
        conflicts,
    };
}

/**
 * Classify parsed changes.  Passing the raw inventory string is also accepted
 * as a convenience; the parser remains pure and is independently exported.
 */
export function classifyChangeSurface(input = [], options = {}) {
    const changes = typeof input === "string" ? parseChangesInventory(input) : input;
    if (!Array.isArray(changes)) {
        throw new TypeError("Changes must be a parsed inventory array or string");
    }
    const normalizedChanges = changes.map((change) => {
        if (!change || typeof change !== "object") {
            throw new TypeError("Each change must be an object");
        }
        const paths = changePaths(change);
        if (!paths.length) throw new Error("Change has no path");
        return { ...change, status: String(change.status ?? "M").trim(), paths };
    });
    const normalizedOptions = normalizeOptions(options);

    let tier = 1;
    let tier3Hit = false;
    let tier2Hit = false;
    let moduleVendorHit = false;
    let renameHit = false;
    let openapiHit = false;
    let mountAuditHit = false;
    let mountAuditToolFixtureHit = false;
    let frontendHit = false;
    let perlHit = false;
    let guardedPerlHit = false;
    let guardedRouteHit = false;
    let guardPolicyHit = false;
    const tier3Paths = new Set();

    for (const change of normalizedChanges) {
        const kind = changeKind(change);
        const paths = change.paths;
        if (kind === "R") renameHit = true;

        if (paths.some(isTier3Path)) {
            tier3Hit = true;
            for (const path of paths) {
                if (isTier3Path(path)) tier3Paths.add(path);
            }
        }

        if ((kind === "A" || kind === "D" || kind === "R") && paths.some(isPublicAssetPath)) {
            tier2Hit = true;
        }

        if (paths.some(isModuleVendorPath)) moduleVendorHit = true;
        if (paths.some(isOpenApiPath)) openapiHit = true;
        if (paths.some(isMountAuditPath)) {
            mountAuditHit = true;
            mountAuditToolFixtureHit = true;
        }
        if (paths.some(isFrontendPath)) frontendHit = true;
        if (paths.some(isPerlPath)) perlHit = true;
        if (paths.some(isGuardedPerlSurface)) guardedPerlHit = true;
        if (paths.some(isGuardedRouteSurface)) guardedRouteHit = true;
        if (paths.some((path) => GUARD_POLICY_SURFACE_RE.test(path))) guardPolicyHit = true;

        if (openapiHit) mountAuditHit = true;
        if ((kind === "M" || kind === "A" || kind === "D" || kind === "R") && paths.some(isPublicAssetPath)) {
            mountAuditHit = true;
        }
    }

    if (tier3Hit) tier = 3;
    else if (tier2Hit) tier = 2;

    const structuralAudit = normalizedOptions.structural
        || moduleVendorHit
        || renameHit
        || openapiHit
        || mountAuditToolFixtureHit;
    const fullGate = tier === 3 || structuralAudit || guardedPerlHit || guardedRouteHit || guardPolicyHit || normalizedOptions.dataRisk;
    const longBrowser = structuralAudit || guardedRouteHit || normalizedOptions.evidence;
    const lane = tier >= 2 || fullGate || normalizedOptions.evidence ? "guarded" : "fast";

    const reasons = new Set();
    for (const path of tier3Paths) {
        reasons.add(`Tier 3 input changed: ${path}`);
    }
    if (tier2Hit) {
        reasons.add("Tier 2 public JS/CSS add, delete, or rename requires a mount audit.");
    }
    if (moduleVendorHit) {
        reasons.add("Structural audit required: module/vendor path changed.");
    }
    if (renameHit) {
        reasons.add("Structural audit required: a rename was detected.");
    }
    if (openapiHit) {
        reasons.add("Structural audit required: OpenAPI changed.");
    }
    if (mountAuditToolFixtureHit) {
        reasons.add("Structural audit required: mount-audit tool or fixture changed.");
    }
    if (guardedPerlHit) {
        reasons.add("Full gate required: guarded model, auth, queue, or runtime Perl surface changed.");
    }
    if (guardedRouteHit) {
        reasons.add("Full gate and browser evidence required: public-route Perl surface changed.");
    }
    if (guardPolicyHit) {
        reasons.add("Full gate required: validation policy or its contract tests changed.");
    }
    if (normalizedOptions.structural) {
        reasons.add("Structural audit explicitly requested.");
    }
    if (normalizedOptions.dataRisk) {
        reasons.add("Full gate explicitly requested for data risk.");
    }
    if (normalizedOptions.evidence) {
        reasons.add("Long browser evidence explicitly requested.");
    }
    if (normalizedOptions.conflicts !== null && normalizedOptions.conflicts > 15) {
        reasons.add(`Warning: conflict count ${normalizedOptions.conflicts} exceeds 15; extra review is recommended.`);
    }

    return {
        tier,
        lane,
        full_gate: fullGate,
        structural_audit: structuralAudit,
        mount_audit: mountAuditHit,
        long_browser: longBrowser,
        frontend: frontendHit,
        perl: perlHit,
        openapi: openapiHit,
        reasons: [...reasons],
    };
}

const OUTPUT_KEYS = [
    "tier",
    "lane",
    "full_gate",
    "structural_audit",
    "mount_audit",
    "long_browser",
    "frontend",
    "perl",
    "openapi",
];

/** Format deterministic key/value lines accepted by GitHub Actions outputs. */
export function formatGithubOutput(result) {
    const lines = OUTPUT_KEYS.map((key) => `${key}=${String(result[key])}`);
    // JSON keeps reasons machine-readable while remaining a single output line.
    lines.push(`reasons=${JSON.stringify(result.reasons)}`);
    return `${lines.join("\n")}\n`;
}

function usage() {
    return "Usage: node tools/classify-change-surface.mjs --changes-file <path> [--github-output <path>] [--data-risk] [--structural] [--evidence] [--conflicts N]";
}

function parseCliArgs(argv) {
    const options = {};
    let changesFile = null;
    let githubOutput = null;
    for (let index = 0; index < argv.length; index += 1) {
        const arg = argv[index];
        if (arg === "--help" || arg === "-h") return { help: true };
        if (arg === "--changes-file" || arg === "--github-output" || arg === "--conflicts") {
            const value = argv[index + 1];
            if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
            index += 1;
            if (arg === "--changes-file") changesFile = value;
            else if (arg === "--github-output") githubOutput = value;
            else options.conflicts = value;
            continue;
        }
        if (arg === "--data-risk") options.dataRisk = true;
        else if (arg === "--structural") options.structural = true;
        else if (arg === "--evidence") options.evidence = true;
        else throw new Error(`Unknown argument: ${arg}`);
    }
    if (!changesFile) throw new Error(`--changes-file is required\n${usage()}`);
    return { changesFile, githubOutput, options };
}

function main(argv = process.argv.slice(2)) {
    try {
        const parsed = parseCliArgs(argv);
        if (parsed.help) {
            console.log(usage());
            return 0;
        }
        const changesPath = resolve(process.cwd(), parsed.changesFile);
        if (!existsSync(changesPath)) throw new Error(`Changes file not found: ${changesPath}`);
        const changes = parseChangesInventory(readFileSync(changesPath, "utf8"));
        const result = classifyChangeSurface(changes, parsed.options);
        console.log(JSON.stringify(result));
        if (parsed.githubOutput) {
            const outputPath = resolve(process.cwd(), parsed.githubOutput);
            appendFileSync(outputPath, formatGithubOutput(result), "utf8");
        }
        return 0;
    } catch (error) {
        console.error(`${error instanceof Error ? error.message : String(error)}`);
        return 2;
    }
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (isMain) process.exitCode = main();
