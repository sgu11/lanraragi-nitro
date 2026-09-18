import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { chromium } from "playwright-core";

// Deterministic synthetic archives: exercises production UI code without
// reading a library or issuing destructive requests to a running service.
const read = (path) => readFile(new URL(`../../${path}`, import.meta.url), "utf8");
const [template, script, css, baseCSS, jquery, translations] = await Promise.all([
    read("templates/duplicates_custom.html.tt2"), read("public/js/duplicates_custom.js"),
    read("public/css/duplicates_custom.css"), read("public/css/lrr.css"),
    read("node_modules/jquery/dist/jquery.min.js"), read("templates/i18n.html.tt2"),
]);
const body = template.split("<body>")[1].split("</body>")[0]
    .replace(/\[% c\.lh\("(.*?)"\) %\]/g, "$1");
const i18n = translations.split("\n").filter((line) => line.startsWith("I18N.Duplicates"))
    .join("\n").replace(/\[% c\.lh\("(.*?)"\) %\]/g, (_, text) => text.replaceAll("\\$", "$"));
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>${baseCSS}\n${css}</style><script type="importmap">{"imports":{"lrr-common":"/common.js","i18n":"/i18n.js"}}</script>
<script src="/jquery.js"></script><script type="module" src="/duplicates.js"></script></head><body>${body}</body></html>`;
const id = (n) => n.toString(16).padStart(40, "0");
const rows = Array.from({ length: 60 }, (_, n) => ({
    id_a: id(2 * n + 1), id_b: id(2 * n + 2), status: "new", score: n % 12, cover_hamming: n % 12,
    a: { arcid: id(2 * n + 1), title: `Synthetic archive ${n + 1} — original`, pagecount: 32,
        arcsize: 24_000_000, tag_count: 12, language: "Korean", cover_width: 1200, cover_height: 1800 },
    b: { arcid: id(2 * n + 2), title: `Synthetic archive ${n + 1} — alternate`, pagecount: 24,
        arcsize: 18_000_000, tag_count: 9, language: "English", cover_width: 900, cover_height: 1350 },
}));
const calls = [];
const errors = [];
let rejectPairs = false;
let statusDelay = 0;
let jobPolls = 0;
let verifiedPairs = {};
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
page.on("pageerror", (error) => errors.push(error.message));
await page.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    calls.push({ path: url.pathname, search: url.search, method: request.method() });
    const text = (body, contentType = "text/javascript") => route.fulfill({ body, contentType });
    const json = (value, status = 200) => route.fulfill({ json: value, status });
    if (url.pathname === "/") return text(html, "text/html");
    if (url.pathname === "/jquery.js") return text(jquery);
    if (url.pathname === "/duplicates.js") return text(`${script}\nwindow.__duplicates = Duplicates;`);
    if (url.pathname === "/i18n.js") return text(`const I18N = {};\n${i18n}\nexport default I18N;`);
    if (url.pathname === "/common.js") return text(`
        export class ApiURL { constructor(path) { this.path = path; } toString() { return this.path; } }
        export function encodeHTML(value) { const node = document.createElement('div'); node.textContent = value; return node.innerHTML.replaceAll('"', '&quot;').replaceAll("'", '&#39;'); }
        export function showPopUp(value) { window.__popup = value; }
    `);
    if (url.pathname.endsWith("/thumbnail")) {
        return text('<svg xmlns="http://www.w3.org/2000/svg" width="600" height="900"><rect width="600" height="900" fill="#315a62"/><circle cx="300" cy="350" r="170" fill="#d9a441"/><text x="300" y="650" text-anchor="middle" font-size="52" fill="white">TEST COVER</text></svg>', "image/svg+xml");
    }
    if (url.pathname === "/api/duplicates/cover/stats") return json({ archives_total: 120, archives_with_coverhashes: 120, deck_size: 60, deck_target: 100 });
    if (url.pathname === "/api/duplicates/cover/pairs") {
        if (rejectPairs) return json({ error: "fixture outage" }, 503);
        const status = url.searchParams.get("status") || "new";
        const filtered = rows.filter((row) => status === "all" || row.status === status);
        const offset = Number(url.searchParams.get("offset") || 0);
        const limit = Number(url.searchParams.get("limit") || 24);
        return json({ pairs: filtered.slice(offset, offset + limit), total: filtered.length, filtered_total: filtered.length });
    }
    if (url.pathname === "/api/duplicates/cover/status") {
        if (statusDelay) await new Promise((resolve) => setTimeout(resolve, statusDelay));
        const body = request.postDataJSON();
        rows.find((row) => `${row.id_a}|${row.id_b}` === body.pair).status = body.status;
        return json({ success: true });
    }
    if (url.pathname === "/api/duplicates/cover/rebuild") return json({ job: 1 });
    if (url.pathname === "/api/duplicates/cover/verify") {
        const batch = request.postDataJSON().pairs;
        verifiedPairs = {};
        for (const row of rows) {
            if (batch.includes(`${row.id_a}|${row.id_b}`)) {
                row.verification = { state: "same_images" };
                verifiedPairs[`${row.id_a}|${row.id_b}`] = row.verification;
            }
        }
        return json({ job: 2 });
    }
    if (url.pathname.startsWith("/api/minion/")) {
        jobPolls++;
        // The real basic status endpoint deliberately omits result; callers
        // needing continuation IDs or verification results must use /detail.
        if (!url.pathname.endsWith("/detail")) return json({ state: "finished", notes: {}, error: "" });
        if (url.pathname.endsWith("/1/detail")) return json({ state: "finished", result: { next_job: 3 } });
        if (url.pathname.endsWith("/2/detail")) return json({ state: "finished", result: { pairs: verifiedPairs } });
        return json({ state: "finished", result: {} });
    }
    if (request.method() === "DELETE") return json({ success: true });
    return route.fulfill({ status: 204, body: "" });
});
const out = process.env.LRR_DUPLICATE_EVIDENCE_DIR || "/tmp/lrr-duplicate-review";
await mkdir(out, { recursive: true });
try {
    await page.goto("http://lrr.test/");
    await page.locator(".dupe-focus-card").waitFor();
    await page.screenshot({ path: `${out}/desktop.png`, fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    const geometry = await page.evaluate(() => {
        const a = document.querySelector(".dupe-side-a").getBoundingClientRect();
        const b = document.querySelector(".dupe-side-b").getBoundingClientRect();
        return { a: {x: a.x, y: a.y, width: a.width}, b: {x: b.x, y: b.y, width: b.width},
            overflow: document.documentElement.scrollWidth > innerWidth };
    });
    assert.equal(geometry.overflow, false, "mobile has no horizontal overflow");
    assert.equal(geometry.a.y, geometry.b.y, "mobile keeps covers side by side");
    await page.screenshot({ path: `${out}/mobile.png`, fullPage: true });

    // Busy actions cannot switch the focused archive or fire held shortcuts.
    statusDelay = 350;
    const firstPair = await page.locator(".dupe-focus-card").getAttribute("data-pair");
    await page.locator('[data-status="same_cover"]').click();
    await page.keyboard.press("n");
    assert.equal(await page.locator(".dupe-focus-card").getAttribute("data-pair"), firstPair);
    await page.waitForFunction(() => !window.__duplicates._reviewActionInFlight);
    statusDelay = 0;
    assert.notEqual(await page.locator(".dupe-focus-card").getAttribute("data-pair"), firstPair);

    // All-state pagination must continue after an entirely reviewed first page.
    await page.selectOption("#status-select", "all");
    await page.waitForFunction(() => window.__duplicates.state.pairs.length === 24);
    await page.evaluate(() => {
        const d = window.__duplicates;
        d.state.pairs.forEach((pair) => d.state.reviewedPairs.add(`${pair.id_a}|${pair.id_b}`));
        d.state.pairs = [];
        return d.loadMorePairs();
    });
    assert.ok(calls.some((call) => call.search.includes("offset=24")), "fetches the next page past reviewed rows");
    assert.equal(await page.evaluate(() => window.__duplicates.state.pairs.length), 24);

    await page.selectOption("#preset-select", "0");
    await page.click("#run-find-cover");
    await page.waitForFunction(() => window.__duplicates._scanInFlight === false);
    assert.ok(calls.some((call) => call.path.endsWith("/rebuild") && call.search === "?threshold=0&retry_failed=0"));
    assert.ok(jobPolls >= 2, "follows the actual deferred sweep job");
    await page.click("#run-verify");
    await page.waitForFunction(() => window.__duplicates._verifyInFlight === false);
    assert.ok(await page.locator(".dupe-reason-chips").innerText().then((text) => text.includes("Same image bytes")));
    assert.equal(calls.filter((call) => call.method === "DELETE").length, 0, "automatic scan and verification never delete");

    rejectPairs = true;
    await page.evaluate(() => window.__duplicates.loadPairs());
    assert.ok(await page.evaluate(() => window.__duplicates.getActivePair() == null), "failed reload cannot act on an invisible old pair");
    assert.match(await page.locator("#dupes-list").innerText(), /Failed to load/);
    assert.deepEqual(errors, [], "no uncaught browser errors");
    await writeFile(`${out}/checks.json`, JSON.stringify({ geometry, jobPolls, errors, passed: true }, null, 2));
    console.log(`Duplicate review Chromium checks passed. Evidence: ${out}`);
} finally {
    await browser.close();
}
