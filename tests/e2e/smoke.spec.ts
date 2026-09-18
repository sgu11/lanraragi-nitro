import { test, expect } from "@playwright/test";

/**
 * Playwright wrapper for the custom browser smokes in tools/browser/.
 * Original scripts (untouched):
 *  - tools/browser/reader-chrome-smoke.mjs
 *  - tools/browser/quickfilter-smoke.mjs
 * This file mirrors their assertions using @playwright/test so `npm run test:e2e`
 * can be used in CI. Keep tools/browser/*-smoke.mjs as source of truth.
 */

test.describe("LRR smoke (playwright wrapper)", () => {
    test("quickfilter regression: index.js single-instantiation & chip toggles (mirrors quickfilter-smoke.mjs)", async ({
        page,
    }) => {
        const indexJsFetchUrls = new Set<string>();
        const dataTablesRequests: string[] = [];

        const baseUrl = test.info().project.use.baseURL as string | undefined;
        const base = baseUrl || "http://127.0.0.1:3000";

        page.on("request", (req) => {
            const u = req.url();
            if (u.includes("/mod/index.js")) indexJsFetchUrls.add(u);
            try {
                if (/\/search$/.test(new URL(u, base).pathname)) {
                    dataTablesRequests.push(`${req.method()} ${u} ${req.postData() ?? ""}`);
                }
            } catch {
                // ignore malformed URLs
            }
        });

        await page.goto("/", { waitUntil: "networkidle" });

        // Chips are rendered by loadCategories() inside the init .then() chain.
        await page.waitForSelector("#NEW_ONLY", { timeout: 8000 }).catch(() => {});

        const chipPresent = !!(await page.$("#NEW_ONLY"));
        const windowToggleCategoryDefined = await page.evaluate(
            () => typeof (window as unknown as { Index?: { toggleCategory?: unknown } }).Index?.toggleCategory === "function",
        );

        // Dismiss any update/changelog overlay + shade that would intercept the click.
        await page.evaluate(() => {
            const ov = document.getElementById("updateOverlay");
            if (ov) (ov as HTMLElement).style.display = "none";
            const sh = document.getElementById("overlay-shade");
            if (sh) (sh as HTMLElement).style.display = "none";
        });

        // This spec is meant to run against a populated LRR. If no chip, warn but don't hard-fail
        // the suite when running on an empty DB – replicate the original script's strictness only when present.
        if (!chipPresent) {
            test.info().annotations.push({ type: "note", description: "NEW_ONLY chip not present (empty library?), skipping strict checks" });
            expect(windowToggleCategoryDefined).toBeTruthy();
            // Single-instantiation guard: index.js must be fetched under exactly one URL when present.
            // If chip missing we still assert the guard when we saw fetches.
            if (indexJsFetchUrls.size > 0) {
                expect(indexJsFetchUrls.size, `index.js fetched under ${indexJsFetchUrls.size} URLs: ${[...indexJsFetchUrls].join(", ")}`).toBe(1);
            }
            return;
        }

        expect(windowToggleCategoryDefined, "window.Index.toggleCategory should be defined").toBeTruthy();

        // Single-instantiation guard: index.js must be fetched under exactly one URL.
        // (Two URLs = dual instantiation = the bug.)
        expect(indexJsFetchUrls.size, `index.js was fetched under ${indexJsFetchUrls.size} URLs (expected 1): ${[...indexJsFetchUrls].join(", ")}`).toBe(1);

        // Ignore the initial library load so the assertion below covers the request caused specifically by toggling the NEW_ONLY chip.
        dataTablesRequests.length = 0;
        await page.click("#NEW_ONLY");
        // Allow the doSearch() -> DataTables AJAX round-trip to fire.
        await page.waitForTimeout(800);

        const selectedCategoryAfter = await page.evaluate(
            () => (window as unknown as { Index?: { selectedCategory?: string } }).Index?.selectedCategory ?? "<undef>",
        );
        const toggledClassAfter = await page.evaluate(() => document.getElementById("NEW_ONLY")?.className ?? "<gone>");

        expect(selectedCategoryAfter, `selectedCategory after click is "${selectedCategoryAfter}", expected "NEW_ONLY"`).toBe("NEW_ONLY");
        expect(toggledClassAfter).toContain("toggled");
        expect(dataTablesRequests.length, "NEW_ONLY did not trigger a DataTables /search request").toBeGreaterThan(0);
        expect(
            dataTablesRequests.some((p) => p.includes("NEW_ONLY")),
            `${dataTablesRequests.length} DataTables search request(s) fired but none carried NEW_ONLY in the payload: ${dataTablesRequests.join(" | ")}`,
        ).toBeTruthy();
    });

    test("reader minimal chrome (mirrors reader-chrome-smoke.mjs)", async ({ page }) => {
        const readerId = process.env.LANRARAGI_READER_ID;
        test.skip(!readerId, "LANRARAGI_READER_ID not set – skip reader chrome smoke (set LANRARAGI_READER_ID=<archive-id>)");

        const baseUrl = (test.info().project.use.baseURL as string) || "http://127.0.0.1:3000";
        const consoleErrors: string[] = [];
        const pageErrors: string[] = [];

        page.on("console", (msg) => {
            if (msg.type() === "error") consoleErrors.push(msg.text());
        });
        page.on("pageerror", (err) => pageErrors.push(err.message));

        await page.goto(baseUrl, { waitUntil: "domcontentloaded" });
        await page.evaluate(() => {
            localStorage.hideHeader = "true";
            localStorage.infiniteScroll = "false";
            localStorage.fitMode = "fit-height";
        });

        const readerUrl = new URL("/reader", baseUrl);
        readerUrl.searchParams.set("id", readerId!);
        await page.goto(readerUrl.toString(), { waitUntil: "networkidle" });
        await page.waitForSelector("body.reader-minimal-chrome", { timeout: 10_000 });

        const result = await page.evaluate(() => {
            const styles = (selector: string) => {
                const element = document.querySelector(selector);
                if (!element) return null;
                const computed = getComputedStyle(element as Element);
                return {
                    display: computed.display,
                    flexDirection: computed.flexDirection,
                    gap: computed.gap,
                    height: computed.height,
                    maxHeight: computed.maxHeight,
                };
            };
            return {
                bodyClass: document.body.className,
                rightControls: styles("#i4 .absolute-right"),
                bottomChrome: styles("#i5"),
                utilityChrome: styles("#i7"),
                image: styles(".reader-image"),
                display: styles("#display"),
                hasReaderChromeStylesheet: [...document.styleSheets].some((sheet) => (sheet as CSSStyleSheet).href?.includes("/css/reader-chrome.css")),
                scrollHeight: document.documentElement.scrollHeight,
                viewportHeight: window.innerHeight,
            };
        });

        expect(result.hasReaderChromeStylesheet, "reader-chrome.css was not loaded").toBeTruthy();
        expect(result.rightControls?.display).toBe("flex");
        expect(result.rightControls?.flexDirection).toBe("column");
        expect(result.rightControls?.gap).toBe("12px");
        expect(result.bottomChrome?.display).toBe("none");
        expect(result.utilityChrome?.display).toBe("none");
        expect(
            result.scrollHeight,
            `reader document scrolls: ${result.scrollHeight}px > ${result.viewportHeight}px`,
        ).toBeLessThanOrEqual(result.viewportHeight + 1);
        expect(pageErrors, `page errors: ${pageErrors.join(" | ")}`).toEqual([]);
        expect(consoleErrors, `console errors: ${consoleErrors.join(" | ")}`).toEqual([]);
    });
});
