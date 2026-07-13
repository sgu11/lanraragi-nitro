// Regression smoke for the "quick filter chip does nothing" bug.
//
// Root cause it guards against: the index template loaded entry modules via
// absolute URLs with a cache-bust query (e.g. /js/$version/mod/index.js?$av),
// while sibling modules imported each other via relative specifiers ("./index.js")
// that resolve to a URL WITHOUT the query. The browser treated those as two
// distinct modules and instantiated index.js twice, splitting module-level
// state (Index.selectedCategory). Clicking a chip set one instance's state,
// but doSearch()/loadCategories() read the other (empty) instance and reverted
// the toggle, so no filter ever reached the backend.
//
// Fix: every cross-module import under public/js/mod goes through an importmap
// alias so entry and internal imports share one canonical URL.
//
// Mirrors tools/browser/reader-chrome-smoke.mjs conventions.
import { existsSync } from "node:fs";
import { chromium } from "playwright-core";

const baseUrl = process.env.LANRARAGI_BASE_URL || "http://localhost:3000";
const chromeCandidates = [
    process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
].filter(Boolean);

const chromePath = chromeCandidates.find((candidate) => existsSync(candidate));

function fail(message) {
    console.error(message);
    process.exit(1);
}

if (!chromePath) {
    fail("Chrome/Chromium was not found. Set CHROME_PATH to a Chrome-compatible executable.");
}

const browser = await chromium.launch({ executablePath: chromePath, headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });

const indexJsFetchUrls = new Set();
const dataTablesRequests = [];
page.on("request", (req) => {
    const u = req.url();
    if (u.includes("/mod/index.js")) indexJsFetchUrls.add(u);
    // DataTables' /search endpoint carries the category in its query/body.
    if (/\/search$/.test(new URL(u, baseUrl).pathname)) {
        dataTablesRequests.push(`${req.method()} ${u} ${req.postData() ?? ""}`);
    }
});

const result = {};
const failures = [];
try {
    await page.goto(baseUrl, { waitUntil: "networkidle" });

    // Chips are rendered by loadCategories() inside the init .then() chain.
    await page.waitForSelector("#NEW_ONLY", { timeout: 8000 }).catch(() => {});

    result.chipPresent = !!(await page.$("#NEW_ONLY"));
    result.windowToggleCategoryDefined = await page.evaluate(() => typeof window.Index?.toggleCategory === "function");

    // Single-instantiation guard: index.js must be fetched under exactly one URL.
    // (Two URLs = dual instantiation = the bug.)
    result.indexJsFetchUrls = [...indexJsFetchUrls];

    // Dismiss any update/changelog overlay + shade that would intercept the click.
    await page.evaluate(() => {
        const ov = document.getElementById("updateOverlay");
        if (ov) ov.style.display = "none";
        const sh = document.getElementById("overlay-shade");
        if (sh) sh.style.display = "none";
    });

    if (result.chipPresent) {
        // Ignore the initial library load so the assertion below covers the
        // request caused specifically by toggling the NEW_ONLY chip.
        dataTablesRequests.length = 0;
        await page.click("#NEW_ONLY");
        // Allow the doSearch() -> DataTables AJAX round-trip to fire.
        await page.waitForTimeout(800);

        result.selectedCategoryAfter = await page.evaluate(() => window.Index?.selectedCategory ?? "<undef>");
        result.toggledClassAfter = await page.evaluate(() => document.getElementById("NEW_ONLY")?.className ?? "<gone>");
        result.dataTablesRequestsCount = dataTablesRequests.length;
        result.dataTablesPayloadsIncludeNewOnly = dataTablesRequests.some((p) => p.includes("NEW_ONLY"));
    }

    if (indexJsFetchUrls.size !== 1) {
        failures.push(`index.js was fetched under ${indexJsFetchUrls.size} URLs (expected 1): ${[...indexJsFetchUrls].join(", ")}`);
    }
    if (result.selectedCategoryAfter !== "NEW_ONLY") {
        failures.push(`selectedCategory after click is "${result.selectedCategoryAfter}", expected "NEW_ONLY"`);
    }
    if (!result.toggledClassAfter?.includes("toggled")) {
        failures.push(`chip class after click is "${result.toggledClassAfter}", expected to include "toggled"`);
    }
    if (result.dataTablesRequestsCount === 0) {
        failures.push("NEW_ONLY did not trigger a DataTables /search request");
    } else if (!result.dataTablesPayloadsIncludeNewOnly) {
        failures.push(`${result.dataTablesRequestsCount} DataTables search request(s) fired but none carried NEW_ONLY in the payload`);
    }
} catch (error) {
    failures.push(`harness error: ${error.message}`);
} finally {
    await browser.close();
}

if (failures.length > 0) {
    console.error(JSON.stringify({ result, failures }, null, 2));
    process.exit(1);
}
console.log(JSON.stringify(result, null, 2));
